--!strict
--!optimize 2

const ReflectionService = game:GetService("ReflectionService")

const Values = require("./values")

export type Property = {
	name: string,
	serialized_name: string,
	type_id: number,
	enum_name: string?,
	special: string?,
	deserialize_only: boolean?,
	read: SecurityCapabilities?,
	write: SecurityCapabilities?,
}
const ALL_CAPABILITIES = SecurityCapabilities.new(table.unpack(Enum.SecurityCapability:GetEnumItems()))
const TYPE_IDS: { [string]: number } = {
	string = 0x01,
	BinaryString = 0x01,
	ProtectedString = 0x01,
	ContentId = 0x01,
	bool = 0x02,
	int = 0x03,
	float = 0x04,
	double = 0x05,
	UDim = 0x06,
	UDim2 = 0x07,
	Ray = 0x08,
	Faces = 0x09,
	Axes = 0x0a,
	BrickColor = 0x0b,
	Color3 = 0x0c,
	Vector2 = 0x0d,
	Vector3 = 0x0e,
	CoordinateFrame = 0x10,
	Enum = 0x12,
	RefType = 0x13,
	Vector3int16 = 0x14,
	NumberSequence = 0x15,
	ColorSequence = 0x16,
	NumberRange = 0x17,
	Rect2D = 0x18,
	PhysicalProperties = 0x19,
	Color3uint8 = 0x1a,
	int64 = 0x1b,
	SharedString = 0x1c,
	NetAssetRef = 0x1c,
	OptionalCoordinateFrame = 0x1e,
	Font = 0x20,
	SecurityCapabilities = 0x21,
	Content = 0x22,
}
-- Reflection exposes the serialized descriptors, but not their scriptable aliases.
const ALIASES: { [string]: { [string]: string } } = {
	Instance = { DefinesCapabilities = "Sandboxed" },
	BasePart = { Color3uint8 = "Color", size = "Size", MaterialVariantSerialized = "MaterialVariant" },
	FormFactorPart = { formFactorRaw = "FormFactor" },
	Part = { shape = "Shape" },
	WeldConstraint = { Part0Internal = "Part0", Part1Internal = "Part1" },
}
const MESH_PROPERTIES: { [string]: string } = {
	MeshId = "MeshId",
	MeshContent = "MeshContent",
	InitialSize = "MeshSize",
	CollisionFidelity = "CollisionFidelity",
	RenderFidelity = "RenderFidelity",
	FluidFidelityInternal = "FluidFidelity",
}

const function get_class(class_name: string)
	return ReflectionService:GetClass(class_name)
end

const function get_properties(class_name: string): { Property }
	const descriptors =
		ReflectionService:GetPropertiesOfClass(class_name, { Security = ALL_CAPABILITIES, ExcludeDisplay = true })
	local by_name: { [string]: any } = {}
	for _, descriptor in descriptors do
		by_name[descriptor.Name] = descriptor
	end
	local properties: { Property } = {}
	for _, descriptor in descriptors do
		const serialized_name: string = descriptor.Name
		const mesh_property = class_name == "MeshPart" and MESH_PROPERTIES[serialized_name] ~= nil
		if
			(not descriptor.Serialized and descriptor.Type.EngineType ~= "Content" and not mesh_property)
			or serialized_name == "Parent"
		then
			continue
		end
		if serialized_name == "CollisionGroupId" and by_name.CollisionGroup ~= nil then
			continue
		end
		local name = serialized_name
		local special: string? = nil
		const aliases = ALIASES[descriptor.Owner]
		if aliases and aliases[name] then
			name = aliases[name]
		end
		if descriptor.Owner == "Instance" and name == "AttributesSerialize" then
			special = "attributes"
		elseif descriptor.Owner == "Instance" and name == "Tags" then
			special = "tags"
		elseif descriptor.Owner == "Model" and name == "WorldPivotData" then
			name = "WorldPivot"
			special = "pivot"
		elseif descriptor.Owner == "Model" and name == "ScaleFactor" then
			special = "scale"
		elseif mesh_property then
			special = "mesh"
			name = MESH_PROPERTIES[serialized_name]
		end
		const script_descriptor = by_name[name] or descriptor
		const type_id = TYPE_IDS[descriptor.Type.EngineType]
		if type_id == nil and descriptor.Type.ScriptType == nil then
			continue
		end
		if special == nil and (script_descriptor.Permits.Read == nil or script_descriptor.Permits.Write == nil) then
			continue
		end
		assert(type_id ~= nil, `unsupported property type {class_name}.{serialized_name}: {descriptor.Type.EngineType}`)
		table.insert(properties, {
			name = name,
			serialized_name = serialized_name,
			type_id = type_id,
			enum_name = descriptor.Type.EnumType,
			special = special,
			deserialize_only = not descriptor.Serialized and (not mesh_property or name == "MeshContent"),
			read = script_descriptor.Permits.Read,
			write = script_descriptor.Permits.Write,
		})
	end
	-- Archivable is scriptable but ReflectionService marks both spellings as non-serialized.
	table.insert(properties, {
		name = "Archivable",
		serialized_name = "archivable",
		type_id = 0x02,
		read = by_name.Archivable.Permits.Read,
		write = by_name.Archivable.Permits.Write,
	})
	table.sort(properties, function(a: Property, b: Property)
		return a.serialized_name < b.serialized_name
	end)
	return properties
end

const function has_capabilities(capabilities: SecurityCapabilities, required: SecurityCapabilities): boolean
	-- Generated API types omit the set overload and declare Contains's return type incorrectly.
	const contains = (capabilities.Contains :: unknown) :: (SecurityCapabilities, SecurityCapabilities) -> boolean
	return contains(capabilities, required)
end

const function can_access(property: Property, capabilities: SecurityCapabilities): boolean
	if property.special == "mesh" then
		return property.read ~= nil and has_capabilities(capabilities, property.read)
	end
	return property.special ~= nil
		or (
			property.read ~= nil
			and property.write ~= nil
			and has_capabilities(capabilities, property.read)
			and has_capabilities(capabilities, property.write)
		)
end

const function get_property(instance: Instance, property: Property): any
	if property.special == "attributes" then
		return Values.serialize_attributes(instance:GetAttributes())
	elseif property.special == "tags" then
		local tags = instance:GetTags()
		table.sort(tags)
		return table.concat(tags, "\0")
	elseif property.special == "scale" then
		return (instance :: any):GetScale()
	else
		return (instance :: any)[property.name]
	end
end

const function set_property(instance: Instance, property: Property, value: any)
	if property.special == "attributes" then
		for name, attribute in Values.deserialize_attributes(value) do
			instance:SetAttribute(name, attribute)
		end
	elseif property.special == "tags" then
		for tag in string.gmatch(value, "[^\0]+") do
			instance:AddTag(tag)
		end
	elseif property.special == "scale" then
		(instance :: any):ScaleTo(value)
	elseif property.special == "pivot" and value == nil then
		return
	else
		(instance :: any)[property.name] = value
	end
end

return {
	get_class = get_class,
	get_properties = get_properties,
	has_capabilities = has_capabilities,
	can_access = can_access,
	get_property = get_property,
	set_property = set_property,
}
