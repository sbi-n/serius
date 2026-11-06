--!strict
--!optimize 2

const AssetService = game:GetService("AssetService")

const Rbxm = require("@self/rbxm")
const Values = require("@self/values")
const Reflection = require("@self/reflection")

export type ModelClass = Rbxm.ModelClass
export type Model = Rbxm.Model

type Values = Values.Values
type Property = Reflection.Property

const MESH_PROPERTIES: { [string]: boolean } = {
	MeshId = true,
	MeshContent = true,
	CollisionFidelity = true,
	RenderFidelity = true,
	FluidFidelity = true,
	PhysicalConfigData = true,
	PhysicsData = true,
}

-- Roots and all descendants are included. References outside that set become nil.
const function serialize_model(model: Instance | { Instance }): buffer
	const roots: { Instance } = if typeof(model) == "Instance" then { model :: Instance } else model :: { Instance }
	const capabilities = SecurityCapabilities.fromCurrent()
	const context = Values.new_context()
	local instances: { Instance } = {}
	local parent_order: { Instance } = {}
	local stack: { { instance: Instance, visited: boolean } } = {}
	for index = #roots, 1, -1 do
		table.insert(stack, { instance = roots[index], visited = false })
	end
	while #stack > 0 do
		const entry = table.remove(stack) :: { instance: Instance, visited: boolean }
		const instance = entry.instance
		assert(typeof(instance) == "Instance", "serialize_model expects an Instance or an array of Instances")
		if entry.visited then
			table.insert(parent_order, instance)
		elseif context.referents[instance] == nil then
			context.referents[instance] = #instances
			table.insert(instances, instance)
			table.insert(stack, { instance = instance, visited = true })
			const children = instance:GetChildren()
			for index = #children, 1, -1 do
				table.insert(stack, { instance = children[index], visited = false })
			end
		end
	end
	local classes: { [string]: { Instance } } = {}
	local class_names = {}
	for _, instance in instances do
		const class_name = instance.ClassName
		if classes[class_name] == nil then
			const descriptor = Reflection.get_class(class_name)
			assert(
				descriptor ~= nil
					and descriptor.Serialized
					and descriptor.Permits.New ~= nil
					and Reflection.has_capabilities(capabilities, descriptor.Permits.New),
				`class {class_name} cannot be serialized as a model instance`
			)
			classes[class_name] = {}
			table.insert(class_names, class_name)
		end
		table.insert(classes[class_name], instance)
	end
	table.sort(class_names)
	local instance_chunks: { buffer } = {}
	local property_chunks: { buffer } = {}
	for class_index, class_name in class_names do
		const members = classes[class_name]
		local content = { bytes = buffer.create(64), position = 0 }
		Values.write_u32(content, class_index - 1)
		Values.write_string(content, class_name)
		Values.write_u8(content, 0)
		Values.write_u32(content, #members)
		local referents = table.create(#members)
		for index, instance in members do
			referents[index] = context.referents[instance]
		end
		Values.write_words(content, referents, #members, "ref")
		table.insert(instance_chunks, Values.finish(content))
		for _, property in Reflection.get_properties(class_name) do
			if property.deserialize_only or not Reflection.can_access(property, capabilities) then
				continue
			end
			local property_values: Values = table.create(#members)
			for index, instance in members do
				property_values[index] = Reflection.get_property(instance, property)
			end
			content = { bytes = buffer.create(64), position = 0 }
			Values.write_u32(content, class_index - 1)
			Values.write_string(content, property.serialized_name)
			Values.write_u8(content, property.type_id)
			Values.write_values(content, property.type_id, property_values, #members, context)
			table.insert(property_chunks, Values.finish(content))
		end
	end
	local children, parent_refs = {}, {}
	for index, instance in parent_order do
		children[index] = context.referents[instance]
		parent_refs[index] = if instance.Parent ~= nil then context.referents[instance.Parent] or -1 else -1
	end
	return Rbxm.write_model(instance_chunks, property_chunks, context.shared_strings, children, parent_refs)
end

const function create_mesh_parts(model: Model, context: Values.Context)
	local requests: { { referent: number, content: Content, options: { [string]: EnumItem } } } = {}
	for _, class in model.classes do
		if class.name ~= "MeshPart" then
			continue
		end
		local properties: { [string]: Values } = {}
		for _, encoded in class.properties do
			const name = if encoded.name == "FluidFidelityInternal" then "FluidFidelity" else encoded.name
			if not MESH_PROPERTIES[name] then
				continue
			end
			local cursor = { bytes = encoded.content, position = encoded.offset }
			properties[name] = Values.read_values(cursor, encoded.type_id, class.instance_count, context)
			assert(
				cursor.position == buffer.len(encoded.content),
				`unexpected trailing data in MeshPart.{encoded.name}`
			)
		end
		const mesh_contents: Values? = properties.MeshContent
		const mesh_ids: Values? = properties.MeshId
		const physical_configs: Values? = properties.PhysicalConfigData
		const physics_data: Values? = properties.PhysicsData
		for index, referent in class.referents do
			const content: Content = if mesh_contents ~= nil
				then mesh_contents[index]
				else Content.fromUri(if mesh_ids ~= nil then mesh_ids[index] else "")
			local options: { [string]: EnumItem } = {}
			for _, name in { "CollisionFidelity", "RenderFidelity", "FluidFidelity" } do
				const property_values: Values? = properties[name]
				if property_values ~= nil then
					options[name] = Values.get_enum(name, property_values[index])
				end
			end
			if options.CollisionFidelity == nil then
				local fidelity = if physical_configs ~= nil
					then Values.read_collision_fidelity(physical_configs[index])
					else nil
				if fidelity == nil and physics_data ~= nil then
					fidelity = Values.read_collision_fidelity(physics_data[index])
				end
				if fidelity ~= nil then
					options.CollisionFidelity = fidelity
				end
			end
			table.insert(requests, { referent = referent, content = content, options = options })
		end
	end
	local pending = #requests
	local failure: string? = nil
	for _, request in requests do
		task.spawn(function()
			const success, message = pcall(function()
				context.instances[request.referent] = if request.content.SourceType == Enum.ContentSourceType.None
					then Instance.new("MeshPart")
					else AssetService:CreateMeshPartAsync(request.content, request.options)
			end)
			if not success and failure == nil then
				failure = `failed to create MeshPart {request.referent}: {message}`
			end
			pending -= 1
		end)
	end
	-- Join every request before propagating errors so cleanup includes late results.
	while pending > 0 do
		task.wait()
	end
	if failure ~= nil then
		error(failure, 0)
	end
end

-- May yield while creating MeshParts. Callers decide where to parent the detached roots.
const function deserialize_model(bytes: buffer): { Instance }
	const model = Rbxm.read_model(bytes)
	const capabilities = SecurityCapabilities.fromCurrent()
	const context = Values.new_context()
	for index, value in model.shared_strings do
		context.shared_strings[index] = buffer.tostring(value)
	end
	local roots: { Instance } = {}
	local success, message = pcall(function()
		local class_count = 0
		local instance_count = 0
		local referents: { [number]: boolean } = {}
		for _, class in model.classes do
			class_count += 1
			const descriptor = Reflection.get_class(class.name)
			assert(
				descriptor ~= nil
					and descriptor.Permits.New ~= nil
					and Reflection.has_capabilities(capabilities, descriptor.Permits.New),
				`class {class.name} cannot be instantiated`
			)
			for _, referent in class.referents do
				assert(referent >= 0 and not referents[referent], "invalid or duplicate instance referent")
				referents[referent] = true
				instance_count += 1
				if class.name ~= "MeshPart" then
					context.instances[referent] = Instance.new(class.name)
				end
			end
		end
		assert(
			class_count == buffer.readu32(bytes, 16) and instance_count == buffer.readu32(bytes, 20),
			"Roblox binary model header count mismatch"
		)
		assert(#model.parent_order == instance_count, "Roblox binary model parent count mismatch")
		local states: { [number]: number } = {}
		for _, referent in model.parent_order do
			local current = referent
			local path = {}
			while current ~= -1 and states[current] ~= 2 do
				assert(referents[current] and model.parents[current] ~= nil, "invalid parent referent")
				assert(states[current] ~= 1, "cycle in Roblox binary model hierarchy")
				states[current] = 1
				table.insert(path, current)
				current = model.parents[current]
			end
			for _, visited in path do
				states[visited] = 2
			end
		end
		create_mesh_parts(model, context)
		local deferred: { { instance: Instance, property: Property, value: any } } = {}
		for _, class in model.classes do
			local properties: { [string]: Property } = {}
			for _, property in Reflection.get_properties(class.name) do
				properties[property.serialized_name] = property
				properties[property.name] = property
			end
			for _, encoded in class.properties do
				const property = properties[encoded.name]
				-- Engine-only and inaccessible properties cannot be restored through Luau.
				if
					property == nil
					or not Reflection.can_access(property, capabilities)
					or (
						property.special == "mesh"
						and (property.write == nil or not Reflection.has_capabilities(capabilities, property.write))
					)
				then
					continue
				end
				local cursor = { bytes = encoded.content, position = encoded.offset }
				const property_values = Values.read_values(cursor, encoded.type_id, class.instance_count, context)
				assert(
					cursor.position == buffer.len(encoded.content),
					`unexpected trailing data in {class.name}.{encoded.name}`
				)
				for index, referent in class.referents do
					const instance = context.instances[referent]
					local value = property_values[index]
					if encoded.type_id == 0x12 then
						assert(property.enum_name ~= nil, "missing enum reflection information")
						value = Values.get_enum(property.enum_name, value)
					elseif encoded.type_id == 0x13 then
						assert(value == -1 or context.instances[value], "invalid property referent")
						value = context.instances[value]
					end
					if
						encoded.type_id == 0x13
						or property.special == "pivot"
						or property.name == "Sandboxed"
						or property.name == "Capabilities"
					then
						table.insert(deferred, { instance = instance, property = property, value = value })
					else
						Reflection.set_property(instance, property, value)
					end
				end
			end
		end
		for _, referent in model.parent_order do
			const instance = context.instances[referent]
			const parent = model.parents[referent]
			if parent == -1 then
				table.insert(roots, instance)
			else
				instance.Parent = context.instances[parent]
			end
		end
		for _, entry in deferred do
			Reflection.set_property(entry.instance, entry.property, entry.value)
		end
	end)
	if not success then
		for _, instance in context.instances do
			instance:Destroy()
		end
		error(message, 0)
	end
	return roots
end

return {
	serialize_model = serialize_model,
	deserialize_model = deserialize_model,
	read_model = Rbxm.read_model,
	read_shared_strings = Rbxm.read_shared_strings,
	internal = Rbxm.internal,
}
