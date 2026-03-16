mod deform_stack;
mod vertex_buffers;

use std::collections::HashSet;
use std::mem::swap;

use glam::{vec3, Vec2, Vec3};

use crate::node::{
	components::{DeformSource, DeformStack, Mask, Masks, Mesh, MeshGroup, TransformStore, ZSort},
	drawables::{CompositeComponents, DrawableKind, TexturedMeshComponents},
	InoxNodeUuid,
};
use crate::params::BindingValues;
use crate::puppet::{InoxNodeTree, Puppet, World};

pub use vertex_buffers::VertexBuffers;

fn collect_delegated_visuals(nodes: &InoxNodeTree, comps: &World, root: InoxNodeUuid, out: &mut Vec<InoxNodeUuid>) {
	fn dfs(nodes: &InoxNodeTree, comps: &World, id: InoxNodeUuid, out: &mut Vec<InoxNodeUuid>) {
		let Some(node) = nodes.get_node(id) else {
			return;
		};
		if !node.enabled {
			return;
		}

		let drawable_kind = DrawableKind::new(id, comps, false);
		if let Some(drawable_kind) = drawable_kind {
			out.push(id);
			// Composite nodes are delegated: they render their own sub-tree, so treat them as recursion boundaries.
			if matches!(drawable_kind, DrawableKind::Composite(_)) {
				return;
			}
		}

		for child in nodes.get_children(id) {
			dfs(nodes, comps, child.uuid, out);
		}
	}

	for child in nodes.get_children(root) {
		dfs(nodes, comps, child.uuid, out);
	}
}

/// Additional info per node for rendering a TexturedMesh:
/// - offset and length of array for mesh point coordinates
/// - offset and length of array for indices of mesh points defining the mesh
///
/// inside `puppet.render_ctx_vertex_buffers`.
pub struct TexturedMeshRenderCtx {
	pub index_offset: u32,
	pub vert_offset: u32,
	pub index_len: usize,
	pub vert_len: usize,
}

/// Additional info per node for rendering a Composite.
pub struct CompositeRenderCtx {
	pub zsorted_children_list: Vec<InoxNodeUuid>,
}

struct MeshGroupDeformCtx {
	id: InoxNodeUuid,
	targets: Vec<InoxNodeUuid>,
	triangles: Vec<[usize; 3]>,
	base_world: Vec<Vec2>,
	delta_world: Vec<Vec2>,
}

/// Additional struct attached to a puppet for rendering.
pub struct RenderCtx {
	/// General compact data buffers for interfacing with the GPU.
	pub vertex_buffers: VertexBuffers,
	/// All nodes that need respective draw method calls:
	/// - including standalone parts and composite parents,
	/// - excluding (TODO: plain mesh masks) and all descendants of composites (delegated visuals).
	root_drawables_zsorted: Vec<InoxNodeUuid>,
	mesh_groups: Vec<MeshGroupDeformCtx>,
	scratch_deforms: Vec<Vec2>,
	scratch_out: Vec<Vec2>,
}

impl RenderCtx {
	/// MODIFIES puppet. In addition to initializing self, installs render contexts in the World of components
	pub(super) fn new(puppet: &mut Puppet) -> Self {
		let nodes = &puppet.nodes;
		let comps = &mut puppet.node_comps;

		let mut nodes_to_deform = HashSet::new();
		for param in &puppet.params {
			param.1.bindings.iter().for_each(|b| {
				if matches!(b.values, BindingValues::Deform(_)) {
					nodes_to_deform.insert(b.node);
				}
			});
		}
		let mesh_groups = {
			fn scan_targets(nodes: &InoxNodeTree, comps: &World, id: InoxNodeUuid, out: &mut Vec<InoxNodeUuid>) {
				if comps.get::<Mesh>(id).is_some() {
					out.push(id);
				}
				// Deformers deform their children themselves; don't recurse into them to avoid double-deforming.
				if comps.get::<MeshGroup>(id).is_some() {
					return;
				}
				for child in nodes.get_children(id) {
					scan_targets(nodes, comps, child.uuid, out);
				}
			}

			let mut mesh_groups = Vec::new();
			for node in nodes.pre_order_iter() {
				if comps.get::<MeshGroup>(node.uuid).is_none() {
					continue;
				}

				let mut targets = Vec::new();
				for child in nodes.get_children(node.uuid) {
					scan_targets(nodes, comps, child.uuid, &mut targets);
				}

				nodes_to_deform.insert(node.uuid);
				for target in &targets {
					nodes_to_deform.insert(*target);
				}

				let (triangles, vert_len) = match comps.get::<Mesh>(node.uuid) {
					Some(mesh) => (
						mesh.indices
							.chunks_exact(3)
							.map(|chunk| [chunk[0] as usize, chunk[1] as usize, chunk[2] as usize])
							.collect::<Vec<_>>(),
						mesh.vertices.len(),
					),
					None => (Vec::new(), 0),
				};

				mesh_groups.push(MeshGroupDeformCtx {
					id: node.uuid,
					targets,
					triangles,
					base_world: vec![Vec2::ZERO; vert_len],
					delta_world: vec![Vec2::ZERO; vert_len],
				});
			}
			mesh_groups
		};

		let mut vertex_buffers = VertexBuffers::default();

		for node in nodes.iter() {
			let Some(drawable_kind) = DrawableKind::new(node.uuid, comps, true) else {
				continue;
			};

			match drawable_kind {
				DrawableKind::TexturedMesh(components) => {
					let (index_offset, vert_offset) = vertex_buffers.push(components.mesh);
					let (index_len, vert_len) = (components.mesh.indices.len(), components.mesh.vertices.len());

					comps.add(
						node.uuid,
						TexturedMeshRenderCtx {
							index_offset,
							vert_offset,
							index_len,
							vert_len,
						},
					);
				}
				DrawableKind::Composite(_components) => {
					// Reference Inochi2D composites gather visuals from their sub-tree and render them
					// inside the composite buffer (delegated visuals).
					let mut children_list = Vec::new();
					collect_delegated_visuals(nodes, comps, node.uuid, &mut children_list);

					comps.add(
						node.uuid,
						CompositeRenderCtx {
							// sort later, before render
							zsorted_children_list: children_list,
						},
					);
				}
			};
		}

		let mut root_drawables_zsorted = Vec::new();
		collect_delegated_visuals(nodes, comps, nodes.root_node_id, &mut root_drawables_zsorted);

		// Add a DeformStack for every node that might receive deforms (params and/or mesh group deformers).
		for node_id in nodes_to_deform {
			let vert_len = match comps.get::<Mesh>(node_id) {
				Some(mesh) => mesh.vertices.len(),
				None => continue,
			};
			comps.add(node_id, DeformStack::new(vert_len));
		}

		Self {
			vertex_buffers,
			root_drawables_zsorted,
			mesh_groups,
			scratch_deforms: Vec::new(),
			scratch_out: Vec::new(),
		}
	}

	/// Reset all `DeformStack`.
	pub(crate) fn reset(&mut self, nodes: &InoxNodeTree, comps: &mut World) {
		for node in nodes.iter() {
			if let Some(deform_stack) = comps.get_mut::<DeformStack>(node.uuid) {
				deform_stack.reset();
			}
		}
	}

	fn apply_mesh_groups(&mut self, nodes: &InoxNodeTree, comps: &mut World) {
		const INSIDE_EPS: f32 = -1e-4;
		const BOUNDS_EPS: f32 = 1e-4;

		for mg in &mut self.mesh_groups {
			// 1) compute base cage points and per-vertex delta (world space)
			let any_delta = {
				let Some(mesh) = comps.get::<Mesh>(mg.id) else {
					continue;
				};
				let Some(transform) = comps.get::<TransformStore>(mg.id) else {
					continue;
				};

				let vert_len = mesh.vertices.len();
				mg.base_world.resize(vert_len, Vec2::ZERO);
				mg.delta_world.resize(vert_len, Vec2::ZERO);

				self.scratch_deforms.resize(vert_len, Vec2::ZERO);
				if let Some(stack) = comps.get::<DeformStack>(mg.id) {
					stack.combine(nodes, comps, &mut self.scratch_deforms);
				} else {
					self.scratch_deforms.fill(Vec2::ZERO);
				}

				let mut any_delta = false;
				for (i, v) in mesh.vertices.iter().enumerate() {
					let base_local = *v - mesh.origin;
					let base_world = transform
						.absolute
						.transform_point3(vec3(base_local.x, base_local.y, 0.0))
						.truncate();

					let deform_local = self.scratch_deforms[i];
					let deformed_local = base_local + deform_local;
					let deformed_world = transform
						.absolute
						.transform_point3(vec3(deformed_local.x, deformed_local.y, 0.0))
						.truncate();

					let delta_world = deformed_world - base_world;

					mg.base_world[i] = base_world;
					mg.delta_world[i] = delta_world;

					if !any_delta && delta_world.length_squared() > 0.0 {
						any_delta = true;
					}
				}
				any_delta
			};

			if !any_delta || mg.triangles.is_empty() {
				continue;
			}

			// 2) deform targets (local space), using barycentric weights on the base cage triangles.
			let source = DeformSource::Node(mg.id);

			for &target_id in &mg.targets {
				let mut target_vert_len = 0usize;

				{
					let Some(mesh) = comps.get::<Mesh>(target_id) else {
						continue;
					};
					let Some(transform) = comps.get::<TransformStore>(target_id) else {
						continue;
					};

					target_vert_len = mesh.vertices.len();

					self.scratch_deforms.resize(target_vert_len, Vec2::ZERO);
					if let Some(stack) = comps.get::<DeformStack>(target_id) {
						stack.combine(nodes, comps, &mut self.scratch_deforms);
					} else {
						self.scratch_deforms.fill(Vec2::ZERO);
					}

					self.scratch_out.resize(target_vert_len, Vec2::ZERO);
					self.scratch_out.fill(Vec2::ZERO);

					let inv_target_transform = transform.absolute.inverse();

					for (j, v) in mesh.vertices.iter().enumerate() {
						let base_local = *v - mesh.origin;
						let deformed_local = base_local + self.scratch_deforms[j];
						let p_world = transform
							.absolute
							.transform_point3(vec3(deformed_local.x, deformed_local.y, 0.0))
							.truncate();

						for [i0, i1, i2] in &mg.triangles {
							if *i0 >= mg.base_world.len() || *i1 >= mg.base_world.len() || *i2 >= mg.base_world.len() {
								continue;
							}

							let a = mg.base_world[*i0];
							let b = mg.base_world[*i1];
							let c = mg.base_world[*i2];

							let min_x = a.x.min(b.x.min(c.x)) - BOUNDS_EPS;
							let max_x = a.x.max(b.x.max(c.x)) + BOUNDS_EPS;
							let min_y = a.y.min(b.y.min(c.y)) - BOUNDS_EPS;
							let max_y = a.y.max(b.y.max(c.y)) + BOUNDS_EPS;

							if p_world.x < min_x || p_world.x > max_x || p_world.y < min_y || p_world.y > max_y {
								continue;
							}

							let Some(bc) = barycentric(a, b, c, p_world) else {
								continue;
							};
							if bc.x < INSIDE_EPS || bc.y < INSIDE_EPS || bc.z < INSIDE_EPS {
								continue;
							}

							let delta_world =
								mg.delta_world[*i0] * bc.x + mg.delta_world[*i1] * bc.y + mg.delta_world[*i2] * bc.z;

							let delta_local = inv_target_transform
								.transform_vector3(vec3(delta_world.x, delta_world.y, 0.0))
								.truncate();
							self.scratch_out[j] = delta_local;
							break;
						}
					}
				}

				let Some(target_stack) = comps.get_mut::<DeformStack>(target_id) else {
					continue;
				};
				let out = target_stack.begin_direct(source);
				out.copy_from_slice(&self.scratch_out[..target_vert_len]);
			}
		}
	}

	/// Update zsort-ordered info and deform buffer content inside self, according to updated puppet.
	pub(crate) fn update(&mut self, nodes: &InoxNodeTree, comps: &mut World) {
		self.apply_mesh_groups(nodes, comps);
		// root is definitely not a drawable.
		for node in nodes.iter().skip(1) {
			let Some(drawable_kind) = DrawableKind::new(node.uuid, comps, false) else {
				continue;
			};

			match drawable_kind {
				// for Composite, update zsorted children list
				DrawableKind::Composite(_components) => {
					// `swap()` usage is a trick that both:
					// - returns mut borrowed comps early
					// - does not involve any heap allocations
					let mut zsorted_children_list = Vec::new();
					swap(
						&mut zsorted_children_list,
						&mut comps
							.get_mut::<CompositeRenderCtx>(node.uuid)
							.unwrap()
							.zsorted_children_list,
					);

					zsorted_children_list.sort_by(|a, b| {
						let za = comps.get::<ZSort>(*a).unwrap().0;
						let zb = comps.get::<ZSort>(*b).unwrap().0;
						za.total_cmp(&zb).reverse()
					});

					swap(
						&mut zsorted_children_list,
						&mut comps
							.get_mut::<CompositeRenderCtx>(node.uuid)
							.unwrap()
							.zsorted_children_list,
					);
				}
				// for TexturedMesh, obtain and write deforms into vertex_buffer
				DrawableKind::TexturedMesh(_components) => {
					// A TexturedMesh not having an associated DeformStack means it will not be deformed at all, skip.
					if let Some(deform_stack) = comps.get::<DeformStack>(node.uuid) {
						let render_ctx = comps.get::<TexturedMeshRenderCtx>(node.uuid).unwrap();
						let vert_offset = render_ctx.vert_offset as usize;
						let vert_len = render_ctx.vert_len;
						deform_stack.combine(
							nodes,
							comps,
							&mut self.vertex_buffers.deforms[vert_offset..(vert_offset + vert_len)],
						);
					}
				}
			}
		}

		self.root_drawables_zsorted.sort_by(|a, b| {
			let za = comps.get::<ZSort>(*a).unwrap().0;
			let zb = comps.get::<ZSort>(*b).unwrap().0;
			za.total_cmp(&zb).reverse()
		});
	}
}

fn barycentric(a: Vec2, b: Vec2, c: Vec2, p: Vec2) -> Option<Vec3> {
	// https://gamemath.com/book/geomprims.html#barycentric_coordinates
	let v0 = b - a;
	let v1 = c - a;
	let v2 = p - a;

	let d00 = v0.dot(v0);
	let d01 = v0.dot(v1);
	let d11 = v1.dot(v1);
	let d20 = v2.dot(v0);
	let d21 = v2.dot(v1);

	let denom = d00 * d11 - d01 * d01;
	if denom.abs() < 1e-8 {
		return None;
	}

	let v = (d11 * d20 - d01 * d21) / denom;
	let w = (d00 * d21 - d01 * d20) / denom;
	let u = 1.0 - v - w;

	Some(Vec3::new(u, v, w))
}

/// Same as the reference Inochi2D implementation, Inox2D also aims for a "bring your own rendering backend" design.
/// A custom backend shall implement this trait.
///
/// It is perfectly fine that the trait implementation does not contain everything needed to display a puppet as:
/// - The renderer may not be directly rendering to the screen for flexibility.
/// - The renderer may want platform-specific optimizations, e.g. batching, and the provided implementation is merely for collecting puppet info.
/// - The renderer may be a debug/just-for-fun renderer intercepting draw calls for other purposes.
///
/// Either way, the point is Inox2D will implement a `draw()` method for any `impl InoxRenderer`, dispatching calls based on puppet structure according to Inochi2D standard.
pub trait InoxRenderer {
	/// Begin masking.
	///
	/// Ref impl: Clear and start writing to the stencil buffer, lock the color buffer.
	fn on_begin_masks(&self, masks: &Masks);
	/// Get prepared for rendering a singular Mask.
	fn on_begin_mask(&self, mask: &Mask);
	/// Get prepared for rendering masked content.
	///
	/// Ref impl: Read only from the stencil buffer, unlock the color buffer.
	fn on_begin_masked_content(&self);
	/// End masking.
	///
	/// Ref impl: Disable the stencil buffer.
	fn on_end_mask(&self);

	/// Draw TexturedMesh content.
	// TODO: TexturedMesh without any texture (usually for mesh masks)?
	fn draw_textured_mesh_content(
		&self,
		as_mask: bool,
		components: &TexturedMeshComponents,
		render_ctx: &TexturedMeshRenderCtx,
		id: InoxNodeUuid,
	);

	/// Begin compositing. Get prepared for rendering children of a Composite.
	///
	/// Ref impl: Prepare composite buffers.
	fn begin_composite_content(
		&self,
		as_mask: bool,
		components: &CompositeComponents,
		render_ctx: &CompositeRenderCtx,
		id: InoxNodeUuid,
	);
	/// End compositing.
	///
	/// Ref impl: Transfer content from composite buffers to normal buffers.
	fn finish_composite_content(
		&self,
		as_mask: bool,
		components: &CompositeComponents,
		render_ctx: &CompositeRenderCtx,
		id: InoxNodeUuid,
	);
}

pub trait InoxRendererExt {
	/// Draw a Drawable, which is potentially masked.
	fn draw_drawable(&self, as_mask: bool, comps: &World, id: InoxNodeUuid);

	/// Draw one composite. `components` must be referencing `comps`.
	fn draw_composite(&self, as_mask: bool, comps: &World, components: &CompositeComponents, id: InoxNodeUuid);

	/// Iterate over top-level drawables (excluding masks) in zsort order,
	/// and make draw calls correspondingly.
	///
	/// This effectively draws the complete puppet.
	fn draw(&self, puppet: &Puppet);
}

impl<T: InoxRenderer> InoxRendererExt for T {
	fn draw_drawable(&self, as_mask: bool, comps: &World, id: InoxNodeUuid) {
		let drawable_kind = DrawableKind::new(id, comps, false).expect("Node must be a Drawable.");
		let masks = match drawable_kind {
			DrawableKind::TexturedMesh(ref components) => &components.drawable.masks,
			DrawableKind::Composite(ref components) => &components.drawable.masks,
		};

		let mut has_masks = false;
		// In reference Inochi2D, when a drawable is being rendered as a mask (defineMask pass),
		// it does not recursively apply its own masks.
		if !as_mask {
			if let Some(ref masks) = masks {
				has_masks = true;
				self.on_begin_masks(masks);
				for mask in &masks.masks {
					self.on_begin_mask(mask);

					self.draw_drawable(true, comps, mask.source);
				}
				self.on_begin_masked_content();
			}
		}

		match drawable_kind {
			DrawableKind::TexturedMesh(ref components) => {
				self.draw_textured_mesh_content(as_mask, components, comps.get(id).unwrap(), id)
			}
			DrawableKind::Composite(ref components) => self.draw_composite(as_mask, comps, components, id),
		}

		if has_masks {
			self.on_end_mask();
		}
	}

	fn draw_composite(&self, as_mask: bool, comps: &World, components: &CompositeComponents, id: InoxNodeUuid) {
		let render_ctx = comps.get::<CompositeRenderCtx>(id).unwrap();
		if render_ctx.zsorted_children_list.is_empty() {
			// Optimization: Nothing to be drawn, skip context switching
			return;
		}

		self.begin_composite_content(as_mask, components, render_ctx, id);

		for uuid in &render_ctx.zsorted_children_list {
			self.draw_drawable(as_mask, comps, *uuid);
		}

		self.finish_composite_content(as_mask, components, render_ctx, id);
	}

	/// Dispatches draw calls for all nodes of `puppet`
	/// - with provided renderer implementation,
	/// - in Inochi2D standard defined order.
	///
	/// This does not guarantee the display of a puppet on screen due to these possible reasons:
	/// - Only provided `InoxRenderer` method implementations are called.
	///
	/// For example, maybe the caller still need to transfer content from a texture buffer to the screen surface buffer.
	/// - The provided `InoxRender` implementation is wrong.
	/// - `puppet` here does not belong to the `model` this `renderer` is initialized with. This will likely result in panics for non-existent node uuids.
	fn draw(&self, puppet: &Puppet) {
		for uuid in &puppet
			.render_ctx
			.as_ref()
			.expect("RenderCtx of puppet must be initialized before calling draw().")
			.root_drawables_zsorted
		{
			self.draw_drawable(false, &puppet.node_comps, *uuid);
		}
	}
}
