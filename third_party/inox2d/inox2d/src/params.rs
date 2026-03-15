use std::collections::HashMap;

use glam::{vec2, Vec2};

use crate::math::{
	deform::Deform,
	interp::{bi_interpolate_f32, bi_interpolate_vec2s_additive, InterpRange, InterpolateMode},
	matrix::Matrix2d,
};
use crate::node::{
	components::{DeformSource, DeformStack, Mesh, TransformStore, ZSort},
	InoxNodeUuid,
};
use crate::puppet::{InoxNodeTree, Puppet, World};

/// Parameter binding to a node. This allows to animate a node based on the value of the parameter that owns it.
pub struct Binding {
	pub node: InoxNodeUuid,
	pub is_set: Matrix2d<bool>,
	pub interpolate_mode: InterpolateMode,
	pub values: BindingValues,
}

trait ReinterpValue: Clone {
	fn add(a: &Self, b: &Self) -> Self;
	fn sub(a: &Self, b: &Self) -> Self;
	fn mul_scalar(a: &Self, s: f32) -> Self;

	fn lerp(a: &Self, b: &Self, t: f32) -> Self {
		let a = Self::mul_scalar(a, 1.0 - t);
		let b = Self::mul_scalar(b, t);
		Self::add(&a, &b)
	}
}

impl ReinterpValue for f32 {
	#[inline]
	fn add(a: &Self, b: &Self) -> Self {
		a + b
	}

	#[inline]
	fn sub(a: &Self, b: &Self) -> Self {
		a - b
	}

	#[inline]
	fn mul_scalar(a: &Self, s: f32) -> Self {
		a * s
	}
}

impl ReinterpValue for Vec<Vec2> {
	fn add(a: &Self, b: &Self) -> Self {
		debug_assert_eq!(a.len(), b.len(), "ReinterpValue::add length mismatch");
		let mut out = Vec::with_capacity(a.len());
		out.extend(a.iter().zip(b).map(|(a, b)| *a + *b));
		out
	}

	fn sub(a: &Self, b: &Self) -> Self {
		debug_assert_eq!(a.len(), b.len(), "ReinterpValue::sub length mismatch");
		let mut out = Vec::with_capacity(a.len());
		out.extend(a.iter().zip(b).map(|(a, b)| *a - *b));
		out
	}

	fn mul_scalar(a: &Self, s: f32) -> Self {
		let mut out = Vec::with_capacity(a.len());
		out.extend(a.iter().map(|a| *a * s));
		out
	}

	fn lerp(a: &Self, b: &Self, t: f32) -> Self {
		debug_assert_eq!(a.len(), b.len(), "ReinterpValue::lerp length mismatch");
		let mut out = Vec::with_capacity(a.len());
		let ta = 1.0 - t;
		out.extend(a.iter().zip(b).map(|(a, b)| *a * ta + *b * t));
		out
	}
}

#[derive(Debug, Clone)]
pub enum BindingValues {
	ZSort(Matrix2d<f32>),
	TransformTX(Matrix2d<f32>),
	TransformTY(Matrix2d<f32>),
	TransformSX(Matrix2d<f32>),
	TransformSY(Matrix2d<f32>),
	TransformRX(Matrix2d<f32>),
	TransformRY(Matrix2d<f32>),
	TransformRZ(Matrix2d<f32>),
	Deform(Matrix2d<Vec<Vec2>>),
	// TODO
	Opacity,
}

#[derive(Debug, Clone)]
pub struct AxisPoints {
	pub x: Vec<f32>,
	pub y: Vec<f32>,
}

impl Binding {
	pub(crate) fn reinterpolate_values(&mut self, axis_points: &AxisPoints) {
		match &mut self.values {
			BindingValues::ZSort(vals)
			| BindingValues::TransformTX(vals)
			| BindingValues::TransformTY(vals)
			| BindingValues::TransformSX(vals)
			| BindingValues::TransformSY(vals)
			| BindingValues::TransformRX(vals)
			| BindingValues::TransformRY(vals)
			| BindingValues::TransformRZ(vals) => {
				reinterpolate_matrix(vals, &self.is_set, axis_points);
			}
			BindingValues::Deform(vals) => {
				reinterpolate_matrix(vals, &self.is_set, axis_points);
			}
			BindingValues::Opacity => {}
		}
	}
}

fn ranges_out(
	matrix: &Matrix2d<f32>,
	x_mindex: usize,
	x_maxdex: usize,
	y_mindex: usize,
	y_maxdex: usize,
) -> (InterpRange<f32>, InterpRange<f32>) {
	let out_top = InterpRange::new(matrix[(x_mindex, y_mindex)], matrix[(x_maxdex, y_mindex)]);
	let out_btm = InterpRange::new(matrix[(x_mindex, y_maxdex)], matrix[(x_maxdex, y_maxdex)]);
	(out_top, out_btm)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ParamUuid(pub u32);

/// Parameter. A simple bounded value that is used to animate nodes through bindings.
pub struct Param {
	pub uuid: ParamUuid,
	pub name: String,
	pub is_vec2: bool,
	pub min: Vec2,
	pub max: Vec2,
	pub defaults: Vec2,
	pub axis_points: AxisPoints,
	pub bindings: Vec<Binding>,
}

impl Param {
	pub(crate) fn reinterpolate_bindings(&mut self) {
		for binding in &mut self.bindings {
			binding.reinterpolate_values(&self.axis_points);
		}
	}

	/// Internal function that modifies puppet components according to one param set.
	/// Must be only called ONCE per frame to ensure correct behavior.
	///
	/// End users may repeatedly apply a same parameter for multiple times in between frames,
	/// but other facilities should be present to make sure this `apply()` is only called once per parameter.
	pub(crate) fn apply(&self, val: Vec2, nodes: &InoxNodeTree, comps: &mut World) {
		let val = val.clamp(self.min, self.max);
		let val_normed = (val - self.min) / (self.max - self.min);

		// calculate axis point indexes
		let (x_mindex, x_maxdex) = {
			let x_temp = self.axis_points.x.binary_search_by(|a| a.total_cmp(&val_normed.x));

			let last_idx = self.axis_points.x.len() - 1;

			match x_temp {
				Ok(_) | Err(_) if last_idx == 0 => (last_idx, last_idx),
				Ok(ind) if ind >= last_idx => (last_idx - 1, last_idx),
				Ok(ind) => (ind, ind + 1),
				Err(0) => (0, 1),
				Err(ind) if ind >= self.axis_points.x.len() => (last_idx - 1, last_idx),
				Err(ind) => (ind - 1, ind),
			}
		};

		let (y_mindex, y_maxdex) = {
			let y_temp = self.axis_points.y.binary_search_by(|a| a.total_cmp(&val_normed.y));

			let last_idx = self.axis_points.y.len() - 1;

			match y_temp {
				Ok(_) | Err(_) if last_idx == 0 => (last_idx, last_idx),
				Ok(ind) if ind >= last_idx => (last_idx - 1, last_idx),
				Ok(ind) => (ind, ind + 1),
				Err(0) => (0, 1),
				Err(ind) if ind >= self.axis_points.y.len() => (last_idx - 1, last_idx),
				Err(ind) => (ind - 1, ind),
			}
		};

		// Apply offset on each binding
		for binding in &self.bindings {
			let range_in = InterpRange::new(
				vec2(self.axis_points.x[x_mindex], self.axis_points.y[y_mindex]),
				vec2(self.axis_points.x[x_maxdex], self.axis_points.y[y_maxdex]),
			);

			let val_normed = val_normed.clamp(range_in.beg, range_in.end);

			match binding.values {
				BindingValues::ZSort(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps.get_mut::<ZSort>(binding.node).unwrap().0 +=
						bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformTX(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps
						.get_mut::<TransformStore>(binding.node)
						.unwrap()
						.relative
						.translation
						.x += bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformTY(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps
						.get_mut::<TransformStore>(binding.node)
						.unwrap()
						.relative
						.translation
						.y += bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformSX(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps.get_mut::<TransformStore>(binding.node).unwrap().relative.scale.x *=
						bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformSY(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps.get_mut::<TransformStore>(binding.node).unwrap().relative.scale.y *=
						bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformRX(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps
						.get_mut::<TransformStore>(binding.node)
						.unwrap()
						.relative
						.rotation
						.x += bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformRY(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps
						.get_mut::<TransformStore>(binding.node)
						.unwrap()
						.relative
						.rotation
						.y += bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::TransformRZ(ref matrix) => {
					let (out_top, out_bottom) = ranges_out(matrix, x_mindex, x_maxdex, y_mindex, y_maxdex);

					comps
						.get_mut::<TransformStore>(binding.node)
						.unwrap()
						.relative
						.rotation
						.z += bi_interpolate_f32(val_normed, range_in, out_top, out_bottom, binding.interpolate_mode);
				}
				BindingValues::Deform(ref matrix) => {
					let out_top = InterpRange::new(
						matrix[(x_mindex, y_mindex)].as_slice(),
						matrix[(x_maxdex, y_mindex)].as_slice(),
					);
					let out_bottom = InterpRange::new(
						matrix[(x_mindex, y_maxdex)].as_slice(),
						matrix[(x_maxdex, y_maxdex)].as_slice(),
					);

					// deform specified by a parameter must be direct, i.e., in the form of displacements of all vertices
					let direct_deform = {
						let Some(mesh) = comps.get::<Mesh>(binding.node) else {
							let target_name = nodes.get_node(binding.node).map(|n| n.name.as_str());
							tracing::error!(
								"Deform param target must have an associated Mesh. (Param: {}, Binding Node: {} ({:?}))",
								self.name,
								target_name.unwrap_or("<NO NAME>"),
								binding.node.0
							);
							continue;
						};

						let vert_len = mesh.vertices.len();
						let mut direct_deform: Vec<Vec2> = Vec::with_capacity(vert_len);
						direct_deform.resize(vert_len, Vec2::ZERO);

						bi_interpolate_vec2s_additive(
							val_normed,
							range_in,
							out_top,
							out_bottom,
							binding.interpolate_mode,
							&mut direct_deform,
						);

						direct_deform
					};

					comps
						.get_mut::<DeformStack>(binding.node)
						.expect("Nodes being deformed must have a DeformStack component.")
						.push(DeformSource::Param(self.uuid), Deform::Direct(direct_deform));
				}
				// TODO
				BindingValues::Opacity => {}
			}
		}
	}
}

struct BindingReinterpolator<'a, T: ReinterpValue> {
	values: &'a mut Matrix2d<T>,
	axis_points: &'a AxisPoints,
	x_count: usize,
	y_count: usize,
	valid: Vec<bool>,
	newly_set: Vec<bool>,
	interp_distance: Vec<f32>,
	commit_points: Vec<(usize, usize)>,
	valid_count: usize,
}

impl<'a, T: ReinterpValue> BindingReinterpolator<'a, T> {
	#[inline]
	fn idx(&self, x: usize, y: usize) -> usize {
		x * self.y_count + y
	}

	#[inline]
	fn xy_from_maj_min(&self, y_major: bool, maj: usize, min: usize) -> (usize, usize) {
		if y_major {
			(min, maj)
		} else {
			(maj, min)
		}
	}

	#[inline]
	fn major_cnt(&self, y_major: bool) -> usize {
		if y_major {
			self.y_count
		} else {
			self.x_count
		}
	}

	#[inline]
	fn minor_cnt(&self, y_major: bool) -> usize {
		if y_major {
			self.x_count
		} else {
			self.y_count
		}
	}

	#[inline]
	fn axis_point(&self, y_major: bool, minor_idx: usize) -> f32 {
		if y_major {
			self.axis_points.x[minor_idx]
		} else {
			self.axis_points.y[minor_idx]
		}
	}

	#[inline]
	fn is_valid_xy(&self, x: usize, y: usize) -> bool {
		self.valid[self.idx(x, y)]
	}

	#[inline]
	fn is_valid(&self, y_major: bool, maj: usize, min: usize) -> bool {
		let (x, y) = self.xy_from_maj_min(y_major, maj, min);
		self.is_valid_xy(x, y)
	}

	#[inline]
	fn is_newly_set(&self, y_major: bool, maj: usize, min: usize) -> bool {
		let (x, y) = self.xy_from_maj_min(y_major, maj, min);
		self.newly_set[self.idx(x, y)]
	}

	#[inline]
	fn get_distance(&self, y_major: bool, maj: usize, min: usize) -> f32 {
		let (x, y) = self.xy_from_maj_min(y_major, maj, min);
		self.interp_distance[self.idx(x, y)]
	}

	#[inline]
	fn get(&self, y_major: bool, maj: usize, min: usize) -> T {
		let (x, y) = self.xy_from_maj_min(y_major, maj, min);
		self.values[(x, y)].clone()
	}

	fn set_xy(&mut self, x: usize, y: usize, val: T, distance: f32, mark_newly: bool) {
		let i = self.idx(x, y);
		if self.valid[i] {
			return;
		}

		*self
			.values
			.get_mut(x, y)
			.expect("Binding values matrix must be indexable for reinterpolation") = val;
		self.interp_distance[i] = distance;
		if mark_newly {
			self.newly_set[i] = true;
		}
		self.commit_points.push((x, y));
	}

	#[inline]
	fn set(&mut self, y_major: bool, maj: usize, min: usize, val: T, distance: f32) {
		let (x, y) = self.xy_from_maj_min(y_major, maj, min);
		self.set_xy(x, y, val, distance, true);
	}

	fn interp(&self, y_major: bool, maj: usize, left: usize, mid: usize, right: usize) -> T {
		let left_off = self.axis_point(y_major, left);
		let mid_off = self.axis_point(y_major, mid);
		let right_off = self.axis_point(y_major, right);
		let denom = right_off - left_off;
		let t = if denom.abs() <= f32::EPSILON {
			0.0
		} else {
			(mid_off - left_off) / denom
		};

		let a = self.get(y_major, maj, left);
		let b = self.get(y_major, maj, right);
		T::lerp(&a, &b, t)
	}

	fn interpolate_1d2d(&mut self, y_major: bool) {
		let mut detected_intersections = false;

		for maj in 0..self.major_cnt(y_major) {
			let cnt = self.minor_cnt(y_major);
			let mut l = 0usize;

			// Find first element set.
			while l < cnt && !self.is_valid(y_major, maj, l) {
				l += 1;
			}
			if l >= cnt {
				continue;
			}

			loop {
				// Advance until before a missing element.
				while l < cnt.saturating_sub(1) && self.is_valid(y_major, maj, l + 1) {
					l += 1;
				}
				if l >= cnt.saturating_sub(1) {
					break;
				}

				// Find next set element.
				let mut r = l + 1;
				while r < cnt && !self.is_valid(y_major, maj, r) {
					r += 1;
				}
				if r >= cnt {
					break;
				}

				for mid in (l + 1)..r {
					let val = self.interp(y_major, maj, l, mid, r);

					// Intersection detection for the second pass.
					if y_major && self.is_newly_set(y_major, maj, mid) {
						if !detected_intersections {
							self.commit_points.clear();
						}
						let existing = self.get(y_major, maj, mid);
						let avg = T::mul_scalar(&T::add(&val, &existing), 0.5);
						self.set(y_major, maj, mid, avg, 0.0);
						detected_intersections = true;
					}

					if !detected_intersections {
						self.set(y_major, maj, mid, val, 0.0);
					}
				}

				l = r;
			}
		}
	}

	fn extrapolate_corners(&mut self) {
		if self.x_count <= 1 || self.y_count <= 1 {
			return;
		}

		let extrapolate_corner = |this: &mut Self, base_x: usize, base_y: usize, off_x: isize, off_y: isize| {
			let tx = (base_x as isize + off_x) as usize;
			let ty = (base_y as isize + off_y) as usize;

			if this.is_valid_xy(tx, ty) {
				return;
			}

			let base = this.values[(base_x, base_y)].clone();
			let vx = this.values[(tx, base_y)].clone();
			let vy = this.values[(base_x, ty)].clone();
			let val = T::sub(&T::add(&vx, &vy), &base);
			this.set_xy(tx, ty, val, 0.0, false);
		};

		for x in 0..(self.x_count - 1) {
			for y in 0..(self.y_count - 1) {
				let v00 = self.is_valid_xy(x, y);
				let v10 = self.is_valid_xy(x + 1, y);
				let v01 = self.is_valid_xy(x, y + 1);
				let v11 = self.is_valid_xy(x + 1, y + 1);

				if v00 && v10 && v01 && !v11 {
					extrapolate_corner(self, x, y, 1, 1);
				} else if v00 && v10 && !v01 && v11 {
					extrapolate_corner(self, x + 1, y, -1, 1);
				} else if v00 && !v10 && v01 && v11 {
					extrapolate_corner(self, x, y + 1, 1, -1);
				} else if !v00 && v10 && v01 && v11 {
					extrapolate_corner(self, x + 1, y + 1, -1, -1);
				}
			}
		}
	}

	fn extend_and_intersect(&mut self, y_major: bool) {
		let mut detected_intersections = false;

		for maj in 0..self.major_cnt(y_major) {
			let cnt = self.minor_cnt(y_major);

			// Find first element set.
			let mut first = 0usize;
			while first < cnt && !self.is_valid(y_major, maj, first) {
				first += 1;
			}
			if first >= cnt {
				continue;
			}

			let origin = self.axis_point(y_major, first);
			let val = self.get(y_major, maj, first);
			for min in 0..first {
				self.set_or_average(y_major, maj, min, val.clone(), origin, &mut detected_intersections);
			}

			// Find last element set.
			let mut last = cnt - 1;
			while last < cnt && !self.is_valid(y_major, maj, last) {
				last = last.saturating_sub(1);
			}

			let origin = self.axis_point(y_major, last);
			let val = self.get(y_major, maj, last);
			for min in (last + 1)..cnt {
				self.set_or_average(y_major, maj, min, val.clone(), origin, &mut detected_intersections);
			}
		}
	}

	fn set_or_average(
		&mut self,
		y_major: bool,
		maj: usize,
		min: usize,
		val: T,
		origin: f32,
		detected_intersections: &mut bool,
	) {
		let min_dist = (self.axis_point(y_major, min) - origin).abs();
		if y_major && self.is_newly_set(y_major, maj, min) {
			if !*detected_intersections {
				self.commit_points.clear();
			}
			let maj_dist = self.get_distance(y_major, maj, min);
			let min_d2 = min_dist * min_dist;
			let maj_d2 = maj_dist * maj_dist;
			let frac = if (min_d2 + maj_d2).abs() <= f32::EPSILON {
				0.5
			} else {
				min_d2 / (min_d2 + maj_d2)
			};

			let existing = self.get(y_major, maj, min);
			let blended = T::add(&T::mul_scalar(&val, 1.0 - frac), &T::mul_scalar(&existing, frac));
			self.set(y_major, maj, min, blended, 0.0);
			*detected_intersections = true;
		}

		if !*detected_intersections {
			self.set(y_major, maj, min, val, min_dist);
		}
	}

	fn run(&mut self) {
		let total_count = self.x_count * self.y_count;

		loop {
			let y_count = self.y_count;
			for (x, y) in self.commit_points.drain(..) {
				let i = x * y_count + y;
				if !self.valid[i] {
					self.valid[i] = true;
					self.valid_count += 1;
				}
			}

			if self.valid_count == total_count {
				break;
			}

			self.newly_set.fill(false);

			// 1D interpolation in X-major then Y-major direction.
			self.interpolate_1d2d(false);
			self.interpolate_1d2d(true);
			if !self.commit_points.is_empty() {
				continue;
			}

			// Corner extrapolation.
			self.extrapolate_corners();
			if !self.commit_points.is_empty() {
				continue;
			}

			// Extend outwards on both axes.
			self.extend_and_intersect(false);
			self.extend_and_intersect(true);
			if !self.commit_points.is_empty() {
				continue;
			}

			// Avoid infinite loops on malformed payloads.
			break;
		}
	}
}

fn reinterpolate_matrix<T: ReinterpValue>(values: &mut Matrix2d<T>, is_set: &Matrix2d<bool>, axis_points: &AxisPoints) {
	let x_count = axis_points.x.len();
	let y_count = axis_points.y.len();
	if x_count == 0 || y_count == 0 {
		return;
	}

	// Matrices are stored transposed so that (x, y) indexing matches the payload layout.
	if values.height() != x_count || values.width() != y_count {
		tracing::error!(
			"Binding values matrix shape mismatch (got {}x{}, expected {}x{})",
			values.height(),
			values.width(),
			x_count,
			y_count
		);
		return;
	}
	if is_set.height() != x_count || is_set.width() != y_count {
		tracing::error!(
			"Binding is_set matrix shape mismatch (got {}x{}, expected {}x{})",
			is_set.height(),
			is_set.width(),
			x_count,
			y_count
		);
		return;
	}

	let total_count = x_count * y_count;
	let mut valid = vec![false; total_count];
	let mut valid_count = 0usize;
	for x in 0..x_count {
		for y in 0..y_count {
			let v = is_set[(x, y)];
			valid[x * y_count + y] = v;
			if v {
				valid_count += 1;
			}
		}
	}
	if valid_count == 0 {
		return;
	}

	let mut interp = BindingReinterpolator {
		values,
		axis_points,
		x_count,
		y_count,
		valid,
		newly_set: vec![false; total_count],
		interp_distance: vec![0.0f32; total_count],
		commit_points: Vec::new(),
		valid_count,
	};
	interp.run();
}

/// Additional struct attached to a puppet for animating through params.
pub struct ParamCtx {
	values: HashMap<String, Vec2>,
}

impl ParamCtx {
	pub(crate) fn new(puppet: &Puppet) -> Self {
		Self {
			values: puppet.params.iter().map(|p| (p.0.to_owned(), p.1.defaults)).collect(),
		}
	}

	/// Reset all params to default value.
	pub(crate) fn reset(&mut self, params: &HashMap<String, Param>) {
		for (name, value) in self.values.iter_mut() {
			*value = params.get(name).unwrap().defaults;
		}
	}

	/// Set param with name to value `val`.
	pub fn set(&mut self, param_name: &str, val: Vec2) -> Result<(), SetParamError> {
		if let Some(value) = self.values.get_mut(param_name) {
			*value = val;
			Ok(())
		} else {
			Err(SetParamError::NoParameterNamed(param_name.to_string()))
		}
	}

	/// Modify components as specified by all params. Must be called ONCE per frame.
	pub(crate) fn apply(&self, params: &HashMap<String, Param>, nodes: &InoxNodeTree, comps: &mut World) {
		// a correct implementation should not care about the order of `.apply()`
		for (param_name, val) in self.values.iter() {
			params.get(param_name).unwrap().apply(*val, nodes, comps);
		}
	}
}

/// Possible errors setting a param.
#[derive(Debug, thiserror::Error)]
pub enum SetParamError {
	#[error("No parameter named {0}")]
	NoParameterNamed(String),
}
