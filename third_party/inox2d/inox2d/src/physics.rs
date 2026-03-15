pub mod pendulum;
pub(crate) mod runge_kutta;

use std::collections::HashMap;

use glam::Vec2;

use crate::node::components::{PhysicsModel, RigidPendulumCtx, SimplePhysics, SpringPendulumCtx, TransformStore};
use crate::params::ParamUuid;
use crate::puppet::{InoxNodeTree, Puppet, World};

/// Global physics parameters for the puppet.
pub struct PuppetPhysics {
	pub pixels_per_meter: f32,
	pub gravity: f32,
}

type SimplePhysicsProps<'a> = (&'a PuppetPhysics, &'a SimplePhysics);

/// Components implementing this will be able to yield a parameter value every frame based on
/// - time history of transforms of the associated node.
/// - Physics simulation.
pub trait SimplePhysicsCtx {
	/// Type of input to the simulation.
	type Anchor;

	/// Convert node transform to input.
	fn calc_anchor(&self, props: &SimplePhysicsProps, transform: &TransformStore) -> Self::Anchor;
	/// Run one step of simulation given input.
	fn tick(&mut self, props: &SimplePhysicsProps, anchor: &Self::Anchor, t: f32, dt: f32);
	/// Convert simulation result into a parameter value to set.
	fn calc_output(&self, props: &SimplePhysicsProps, transform: &TransformStore, anchor: Self::Anchor) -> Vec2;
}

/// Auto implemented trait for all `impl SimplePhysicsCtx`.
trait SimplePhysicsCtxCommon {
	fn update(&mut self, props: &SimplePhysicsProps, transform: &TransformStore, t: f32, dt: f32) -> Vec2;
}

impl<T: SimplePhysicsCtx> SimplePhysicsCtxCommon for T {
	/// Run physics simulation for one frame given provided methods. Handle big `dt` problems.
	fn update(&mut self, props: &SimplePhysicsProps, transform: &TransformStore, t: f32, dt: f32) -> Vec2 {
		// Timestep is limited to 10 seconds.
		// If you're getting 0.1 FPS, you have bigger issues to deal with.
		let mut h = dt.min(10.0);

		let anchor = self.calc_anchor(props, transform);

		// Minimum physics timestep: 0.01s. If not satisfied, break simulation into steps.
		let mut t = t;
		while h > 0.01 {
			self.tick(props, &anchor, t, 0.01);
			t += 0.01;
			h -= 0.01;
		}

		if h < 0.0 {
			h = 0.0;
		}

		// Match Inochi2D behavior: always run one final tick (even if h == 0.0) so the driver can
		// update its output for the current anchor.
		self.tick(props, &anchor, t, h);

		self.calc_output(props, transform, anchor)
	}
}

/// Additional struct attached to a puppet for executing all physics nodes.
pub(crate) struct PhysicsCtx {
	/// Time since first simulation step.
	t: f32,
	param_uuid_to_name: HashMap<ParamUuid, String>,
}

impl PhysicsCtx {
	/// MODIFIES puppet. In addition to initializing self, installs physics contexts in the World of components
	pub fn new(puppet: &mut Puppet) -> Self {
		for node in puppet.nodes.iter() {
			if let Some(simple_physics) = puppet.node_comps.get::<SimplePhysics>(node.uuid) {
				match simple_physics.model_type {
					PhysicsModel::RigidPendulum => puppet.node_comps.add(node.uuid, RigidPendulumCtx::default()),
					PhysicsModel::SpringPendulum => puppet.node_comps.add(node.uuid, SpringPendulumCtx::default()),
				}
			}
		}

		Self {
			t: 0.,
			param_uuid_to_name: puppet.params.iter().map(|p| (p.1.uuid, p.0.to_owned())).collect(),
		}
	}

	pub fn step(
		&mut self,
		puppet_physics: &PuppetPhysics,
		nodes: &InoxNodeTree,
		comps: &mut World,
		dt: f32,
	) -> HashMap<String, Vec2> {
		let mut values_to_apply = HashMap::new();

		if dt < 0.0 {
			panic!("Time travel has happened.");
		}

		for node in nodes.iter() {
			if let Some(simple_physics) = comps.get::<SimplePhysics>(node.uuid) {
				// before we use some Rust dark magic so that two components can be mutably borrowed at the same time,
				// need to clone to workaround comps ownership problem
				let simple_physics = simple_physics.clone();
				let props = &(puppet_physics, &simple_physics);
				let transform = &comps
					.get::<TransformStore>(node.uuid)
					.expect("All nodes with SimplePhysics must have associated TransformStore.")
					.clone();

				let param_value = if let Some(rigid_pendulum_ctx) = comps.get_mut::<RigidPendulumCtx>(node.uuid) {
					Some(rigid_pendulum_ctx.update(props, transform, self.t, dt))
				} else if let Some(spring_pendulum_ctx) = comps.get_mut::<SpringPendulumCtx>(node.uuid) {
					Some(spring_pendulum_ctx.update(props, transform, self.t, dt))
				} else {
					None
				};

				if let Some(param_value) = param_value {
					values_to_apply
						.entry(
							self.param_uuid_to_name
								.get(&simple_physics.param)
								.expect("A SimplePhysics node must reference a valid param.")
								.to_owned(),
						)
						.and_modify(|_| panic!("Two SimplePhysics nodes reference a same param."))
						.or_insert(param_value);
				}
			}
		}

		self.t += dt;

		values_to_apply
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	use glam::{Mat4, Vec2, Vec3};

	use crate::node::components::{PhysicsParamMapMode, PhysicsProps};
	use crate::params::ParamUuid;

	fn make_props(length: f32) -> (PuppetPhysics, SimplePhysics) {
		let puppet_physics = PuppetPhysics {
			pixels_per_meter: 1.0,
			gravity: 9.81,
		};

		let simple_physics = SimplePhysics {
			param: ParamUuid(0),
			model_type: PhysicsModel::RigidPendulum,
			map_mode: PhysicsParamMapMode::XY,
			props: PhysicsProps {
				gravity: 1.0,
				length,
				frequency: 1.0,
				angle_damping: 0.5,
				length_damping: 0.5,
				output_scale: Vec2::ONE,
			},
			local_only: false,
		};

		(puppet_physics, simple_physics)
	}

	#[test]
	fn rigid_pendulum_initializes_to_rest_output_at_dt_zero() {
		let (puppet_physics, simple_physics) = make_props(100.0);
		let props = (&puppet_physics, &simple_physics);

		let transform = TransformStore {
			absolute: Mat4::from_translation(Vec3::new(50.0, 20.0, 0.0)),
			relative: Default::default(),
		};

		let mut ctx = RigidPendulumCtx::default();
		let out = ctx.update(&props, &transform, 0.0, 0.0);

		assert_eq!(out, Vec2::ZERO);
		assert!(ctx.initialized);
		assert_eq!(ctx.bob, Vec2::new(50.0, 120.0));
	}

	#[test]
	fn spring_pendulum_initializes_to_rest_output_at_dt_zero() {
		let (puppet_physics, mut simple_physics) = make_props(100.0);
		simple_physics.model_type = PhysicsModel::SpringPendulum;
		let props = (&puppet_physics, &simple_physics);

		let transform = TransformStore {
			absolute: Mat4::from_translation(Vec3::new(-25.0, 10.0, 0.0)),
			relative: Default::default(),
		};

		let mut ctx = SpringPendulumCtx::default();
		let out = ctx.update(&props, &transform, 0.0, 0.0);

		assert_eq!(out, Vec2::ZERO);
		assert!(ctx.initialized);
		assert_eq!(ctx.state.vars.bob_pos, Vec2::new(-25.0, 110.0));
		assert_eq!(ctx.state.vars.bob_vel, Vec2::ZERO);
	}
}
