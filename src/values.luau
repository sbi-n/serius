--!strict
--!optimize 2

export type Cursor = { bytes: buffer, position: number }
export type Values = { [number]: any }
export type Context = {
	referents: { [Instance]: number },
	instances: { [number]: Instance },
	shared_strings: { string },
	shared_indices: { [string]: number },
}

const UINT32 = 4294967296
const NORMALS = {
	Vector3.new(1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, -1),
}
-- SecurityCapability enum IDs differ from the native mask bits stored in Rbxm.
const CAPABILITY_BITS: { [string]: number } = {
	RunClientScript = 8,
	RunServerScript = 9,
	AccessOutsideWrite = 11,
	AssetRequire = 16,
	LoadString = 17,
	ScriptGlobals = 18,
	CreateInstances = 19,
	Basic = 20,
	Audio = 21,
	DataStore = 22,
	Network = 23,
	Physics = 24,
	UI = 25,
	CSG = 26,
	Chat = 27,
	Animation = 28,
	Avatar = 29,
	Input = 30,
	Environment = 31,
	RemoteEvent = 32,
	LegacySound = 33,
	Players = 34,
	CapabilityControl = 35,
	Plugin = 0,
	LocalUser = 1,
	WritePlayer = 2,
	RobloxScript = 3,
	RobloxEngine = 4,
	Unassigned = 15,
	InternalTest = 60,
	PluginOrOpenCloud = 61,
	Assistant = 62,
	RemoteCommand = 59,
	AssetRead = 36,
	AssetManagement = 37,
	DynamicGeneration = 38,
	PlatformAvatarEditing = 39,
	AssetCreateUpdate = 40,
	Capture = 41,
	SensitiveInput = 42,
	Monetization = 43,
	LoadOwnedAsset = 44,
	Social = 45,
	ServerCommunication = 46,
	Logging = 47,
	PromptExternalPurchase = 48,
	Groups = 49,
	Teleport = 50,
	Consequences = 51,
	Material = 52,
	AvatarBehavior = 53,
	AvatarAppearance = 29,
	LoadUnownedAsset = 16,
}

const function take(cursor: Cursor, length: number): number
	const position = cursor.position
	assert(length >= 0 and position + length <= buffer.len(cursor.bytes), "truncated Roblox binary model data")
	cursor.position += length
	return position
end

const function reserve(cursor: Cursor, length: number): number
	const position = cursor.position
	const required = position + length
	if required > buffer.len(cursor.bytes) then
		local bytes = buffer.create(math.max(required, buffer.len(cursor.bytes) * 2, 64))
		buffer.copy(bytes, 0, cursor.bytes, 0, position)
		cursor.bytes = bytes
	end
	cursor.position = required
	return position
end

const function finish(cursor: Cursor): buffer
	local bytes = buffer.create(cursor.position)
	buffer.copy(bytes, 0, cursor.bytes, 0, cursor.position)
	return bytes
end

const function read_u8(cursor: Cursor): number
	return buffer.readu8(cursor.bytes, take(cursor, 1))
end

const function read_u16(cursor: Cursor): number
	return buffer.readu16(cursor.bytes, take(cursor, 2))
end

const function read_u32(cursor: Cursor): number
	return buffer.readu32(cursor.bytes, take(cursor, 4))
end

const function read_f32(cursor: Cursor): number
	return buffer.readf32(cursor.bytes, take(cursor, 4))
end

const function read_f64(cursor: Cursor): number
	return buffer.readf64(cursor.bytes, take(cursor, 8))
end

const function read_string(cursor: Cursor): string
	const length = read_u32(cursor)
	return buffer.readstring(cursor.bytes, take(cursor, length), length)
end

const function write_u8(cursor: Cursor, value: number)
	const position = reserve(cursor, 1)
	buffer.writeu8(cursor.bytes, position, value)
end

const function write_u16(cursor: Cursor, value: number)
	const position = reserve(cursor, 2)
	buffer.writeu16(cursor.bytes, position, value)
end

const function write_u32(cursor: Cursor, value: number)
	const position = reserve(cursor, 4)
	buffer.writeu32(cursor.bytes, position, value)
end

const function write_f32(cursor: Cursor, value: number)
	const position = reserve(cursor, 4)
	buffer.writef32(cursor.bytes, position, value)
end

const function write_f64(cursor: Cursor, value: number)
	const position = reserve(cursor, 8)
	buffer.writef64(cursor.bytes, position, value)
end

const function write_string(cursor: Cursor, value: string)
	write_u32(cursor, #value)
	const position = reserve(cursor, #value)
	buffer.writestring(cursor.bytes, position, value)
end

const function get_enum(name: string, value: number): EnumItem
	for _, item in (Enum :: any)[name]:GetEnumItems() do
		if item.Value == value then
			return item
		end
	end
	error(`invalid Enum.{name} value {value}`)
end

const function read_collision_fidelity(data: string): EnumItem?
	if #data < 10 or string.sub(data, 1, 6) ~= "CSGPHS" then
		return nil
	end
	const version = string.unpack("<I4", data, 7)
	if version == 0 and string.sub(data, 11, 15) == "BLOCK" then
		return Enum.CollisionFidelity.Box
	elseif (version == 7 or version == 8) and #data >= 11 then
		-- Native physical config tags use a different order from CollisionFidelity.
		const fidelity = ({ 1, 0, 3, 3, 0, 0, 4 })[string.byte(data, 11)]
		if fidelity ~= nil then
			return get_enum("CollisionFidelity", fidelity)
		end
	end
	return nil
end

-- Interleaved big-endian words, optionally transformed or delta encoded.
const function read_words(cursor: Cursor, count: number, kind: string): { number }
	const offset = take(cursor, count * 4)
	const values = table.create(count) :: { number }
	const scratch = buffer.create(4)
	local previous = 0
	for index = 0, count - 1 do
		local value = buffer.readu8(cursor.bytes, offset + index) * 16777216
			+ buffer.readu8(cursor.bytes, offset + count + index) * 65536
			+ buffer.readu8(cursor.bytes, offset + 2 * count + index) * 256
			+ buffer.readu8(cursor.bytes, offset + 3 * count + index)
		if kind == "float" then
			buffer.writeu32(scratch, 0, bit32.rrotate(value, 1))
			value = buffer.readf32(scratch, 0)
		elseif kind == "int" or kind == "ref" then
			value = if value % 2 == 0 then value / 2 else -(value + 1) / 2
			if kind == "ref" then
				value += previous
				previous = value
			end
		end
		values[index + 1] = value
	end
	return values
end

const function write_words(cursor: Cursor, values: Values, count: number, kind: string)
	const offset = reserve(cursor, count * 4)
	const scratch = buffer.create(4)
	local previous = 0
	for index = 0, count - 1 do
		local value: number = values[index + 1]
		if kind == "float" then
			buffer.writef32(scratch, 0, value)
			value = bit32.lrotate(buffer.readu32(scratch, 0), 1)
		elseif kind == "int" or kind == "ref" then
			if kind == "ref" then
				const current = value
				value -= previous
				previous = current
			end
			assert(value % 1 == 0 and value >= -2147483648 and value <= 2147483647, "integer out of range")
			value = if value >= 0 then value * 2 else -value * 2 - 1
		end
		for byte = 0, 3 do
			buffer.writeu8(cursor.bytes, offset + byte * count + index, bit32.extract(value, 24 - byte * 8, 8))
		end
	end
end

const function read_int64s(cursor: Cursor, count: number, capabilities: boolean): Values
	const offset = take(cursor, count * 8)
	local values: Values = table.create(count)
	for index = 0, count - 1 do
		local high, low = 0, 0
		for byte = 0, 7 do
			const value = buffer.readu8(cursor.bytes, offset + byte * count + index)
			if byte < 4 then
				high = high * 256 + value
			else
				low = low * 256 + value
			end
		end
		const negative = low % 2 == 1
		low = math.floor(low / 2) + high % 2 * 2147483648
		high = math.floor(high / 2)
		if capabilities then
			if negative then
				high = bit32.bnot(high)
				low = bit32.bnot(low)
			end
			local items = {}
			for _, item in Enum.SecurityCapability:GetEnumItems() do
				const bit = CAPABILITY_BITS[item.Name]
				assert(bit ~= nil, `unsupported SecurityCapability {item.Name}`)
				const word = if bit < 32 then low else high
				if bit32.btest(word, bit32.lshift(1, bit % 32)) then
					table.insert(items, item)
				end
			end
			values[index + 1] = SecurityCapabilities.new(table.unpack(items))
		else
			values[index + 1] = if negative then -(high * UINT32 + low) - 1 else high * UINT32 + low
		end
	end
	return values
end

const function write_int64s(cursor: Cursor, values: Values, count: number, capabilities: boolean)
	const offset = reserve(cursor, count * 8)
	for index = 0, count - 1 do
		local high, low = 0, 0
		const value = values[index + 1]
		if capabilities then
			for _, item in Enum.SecurityCapability:GetEnumItems() do
				if value:Contains(item) then
					const bit = CAPABILITY_BITS[item.Name]
					assert(bit ~= nil, `unsupported SecurityCapability {item.Name}`)
					if bit < 32 then
						low = bit32.bor(low, bit32.lshift(1, bit))
					else
						high = bit32.bor(high, bit32.lshift(1, bit - 32))
					end
				end
			end
			const negative = high >= 2147483648
			high = (high * 2 + math.floor(low / 2147483648)) % UINT32
			low = low * 2 % UINT32
			if negative then
				high = bit32.bnot(high)
				low = bit32.bnot(low)
			end
		else
			assert(
				value % 1 == 0 and value >= -9223372036854775808 and value < 9223372036854775808,
				"int64 out of range"
			)
			const magnitude = math.abs(value)
			low = magnitude % UINT32
			high = math.floor(magnitude / UINT32)
			high = (high * 2 + math.floor(low / 2147483648)) % UINT32
			low = low * 2 % UINT32
			if value < 0 then
				if low == 0 then
					high = (high - 1) % UINT32
				end
				low = (low - 1) % UINT32
			end
		end
		for byte = 0, 7 do
			const word = if byte < 4 then high else low
			buffer.writeu8(cursor.bytes, offset + byte * count + index, bit32.extract(word, 24 - byte % 4 * 8, 8))
		end
	end
end

const function read_rotation(cursor: Cursor, columns: boolean?): CFrame
	const id = read_u8(cursor)
	if id ~= 0 then
		const right: Vector3? = NORMALS[math.floor((id - 1) / 6) + 1]
		const up: Vector3? = NORMALS[(id - 1) % 6 + 1]
		assert(right ~= nil and up ~= nil and right:Dot(up) == 0, "invalid CFrame rotation ID")
		return CFrame.fromMatrix(Vector3.zero, right, up)
	end
	local values = table.create(9) :: { number }
	for index = 1, 9 do
		values[index] = read_f32(cursor)
	end
	if columns then
		return CFrame.fromMatrix(
			Vector3.zero,
			Vector3.new(values[1], values[2], values[3]),
			Vector3.new(values[4], values[5], values[6]),
			Vector3.new(values[7], values[8], values[9])
		)
	end
	return CFrame.new(
		0,
		0,
		0,
		values[1],
		values[2],
		values[3],
		values[4],
		values[5],
		values[6],
		values[7],
		values[8],
		values[9]
	)
end

const function write_rotation(cursor: Cursor, value: CFrame, columns: boolean?)
	local right, up = nil, nil
	for index, normal in NORMALS do
		if value.XVector == normal then
			right = index - 1
		end
		if value.YVector == normal then
			up = index - 1
		end
	end
	if right ~= nil and up ~= nil then
		write_u8(cursor, right * 6 + up + 1)
		return
	end
	write_u8(cursor, 0)
	if columns then
		for _, vector in { value.XVector, value.YVector, value.ZVector } do
			write_f32(cursor, vector.X)
			write_f32(cursor, vector.Y)
			write_f32(cursor, vector.Z)
		end
	else
		const components = { value:GetComponents() }
		for index = 4, 12 do
			write_f32(cursor, components[index])
		end
	end
end

const COMPONENT_KINDS: { [number]: { string } } = {
	[0x06] = { "float", "int" },
	[0x07] = { "float", "float", "int", "int" },
	[0x0c] = { "float", "float", "float" },
	[0x0d] = { "float", "float" },
	[0x0e] = { "float", "float", "float" },
	[0x18] = { "float", "float", "float", "float" },
}

const function get_components(type_id: number, value: any): { number }
	if type_id == 0x06 then
		return { value.Scale, value.Offset }
	elseif type_id == 0x07 then
		return { value.X.Scale, value.Y.Scale, value.X.Offset, value.Y.Offset }
	elseif type_id == 0x0c then
		return { value.R, value.G, value.B }
	elseif type_id == 0x0d then
		return { value.X, value.Y }
	elseif type_id == 0x0e then
		return { value.X, value.Y, value.Z }
	else
		return { value.Min.X, value.Min.Y, value.Max.X, value.Max.Y }
	end
end

const function from_components(type_id: number, values: { number }): any
	if type_id == 0x06 then
		return UDim.new(values[1], values[2])
	elseif type_id == 0x07 then
		return UDim2.new(values[1], values[3], values[2], values[4])
	elseif type_id == 0x0c then
		return Color3.new(values[1], values[2], values[3])
	elseif type_id == 0x0d then
		return Vector2.new(values[1], values[2])
	elseif type_id == 0x0e then
		return Vector3.new(values[1], values[2], values[3])
	else
		return Rect.new(values[1], values[2], values[3], values[4])
	end
end

const function read_value(cursor: Cursor, type_id: number, attribute: boolean?): any
	if type_id == 0x01 then
		return read_string(cursor)
	elseif type_id == 0x02 then
		return read_u8(cursor) ~= 0
	elseif type_id == 0x03 then
		return buffer.readi32(cursor.bytes, take(cursor, 4))
	elseif type_id == 0x04 then
		return read_f32(cursor)
	elseif type_id == 0x05 then
		return read_f64(cursor)
	elseif type_id == 0x08 then
		return Ray.new(
			Vector3.new(read_f32(cursor), read_f32(cursor), read_f32(cursor)),
			Vector3.new(read_f32(cursor), read_f32(cursor), read_f32(cursor))
		)
	elseif type_id == 0x09 or type_id == 0x0a then
		const mask = read_u8(cursor)
		local items = {}
		const enum: any = if type_id == 0x09 then Enum.NormalId else Enum.Axis
		for _, item in enum:GetEnumItems() do
			if bit32.btest(mask, bit32.lshift(1, item.Value)) then
				table.insert(items, item)
			end
		end
		return if type_id == 0x09 then Faces.new(table.unpack(items)) else Axes.new(table.unpack(items))
	elseif type_id == 0x0b then
		return BrickColor.new(read_u32(cursor))
	elseif type_id == 0x10 then
		const position = Vector3.new(read_f32(cursor), read_f32(cursor), read_f32(cursor))
		return read_rotation(cursor, true) + position
	elseif type_id == 0x12 then
		return get_enum(read_string(cursor), read_u32(cursor))
	elseif type_id == 0x14 then
		const offset = take(cursor, 6)
		return Vector3int16.new(
			buffer.readi16(cursor.bytes, offset),
			buffer.readi16(cursor.bytes, offset + 2),
			buffer.readi16(cursor.bytes, offset + 4)
		)
	elseif type_id == 0x15 or type_id == 0x16 then
		const keypoint_count = read_u32(cursor)
		assert(
			keypoint_count <= (buffer.len(cursor.bytes) - cursor.position) / (if type_id == 0x15 then 12 else 20),
			"truncated sequence"
		)
		if type_id == 0x15 then
			local keypoints = table.create(keypoint_count) :: { NumberSequenceKeypoint }
			for keypoint = 1, keypoint_count do
				const first, second, third = read_f32(cursor), read_f32(cursor), read_f32(cursor)
				keypoints[keypoint] = if attribute
					then NumberSequenceKeypoint.new(second, third, first)
					else NumberSequenceKeypoint.new(first, second, third)
			end
			return NumberSequence.new(keypoints)
		else
			local keypoints = table.create(keypoint_count) :: { ColorSequenceKeypoint }
			for keypoint = 1, keypoint_count do
				if attribute then
					read_f32(cursor) -- unused envelope precedes attribute keypoints
				end
				const time = read_f32(cursor)
				keypoints[keypoint] =
					ColorSequenceKeypoint.new(time, Color3.new(read_f32(cursor), read_f32(cursor), read_f32(cursor)))
				if not attribute then
					read_f32(cursor) -- unused envelope follows property keypoints
				end
			end
			return ColorSequence.new(keypoints)
		end
	elseif type_id == 0x17 then
		return NumberRange.new(read_f32(cursor), read_f32(cursor))
	elseif type_id == 0x19 then
		const flags = read_u8(cursor)
		if bit32.btest(flags, 1) then
			const density, friction, elasticity = read_f32(cursor), read_f32(cursor), read_f32(cursor)
			const friction_weight, elasticity_weight = read_f32(cursor), read_f32(cursor)
			const absorption = if bit32.btest(flags, 2) then read_f32(cursor) else 1
			return PhysicalProperties.new(density, friction, elasticity, friction_weight, elasticity_weight, absorption)
		end
	elseif type_id == 0x20 then
		local family = if not attribute then read_string(cursor) else ""
		const weight, style = read_u16(cursor), read_u8(cursor)
		if attribute then
			family = read_string(cursor)
		end
		read_string(cursor) -- cached face IDs are not exposed to scripts
		return Font.new(
			family,
			get_enum("FontWeight", weight) :: Enum.FontWeight,
			get_enum("FontStyle", style) :: Enum.FontStyle
		)
	else
		error(`unsupported Roblox binary property type 0x{string.format("%02x", type_id)}`)
	end
	return nil
end

const function write_value(cursor: Cursor, type_id: number, value: any, attribute: boolean?)
	if type_id == 0x01 then
		write_string(cursor, value)
	elseif type_id == 0x02 then
		write_u8(cursor, if value then 1 else 0)
	elseif type_id == 0x05 then
		write_f64(cursor, value)
	elseif type_id == 0x08 then
		for _, vector in { value.Origin, value.Direction } do
			write_f32(cursor, vector.X)
			write_f32(cursor, vector.Y)
			write_f32(cursor, vector.Z)
		end
	elseif type_id == 0x09 or type_id == 0x0a then
		local mask = 0
		const names: { string } = if type_id == 0x09
			then { "Right", "Top", "Back", "Left", "Bottom", "Front" }
			else { "X", "Y", "Z" }
		for bit, name in names do
			if value[name] then
				mask = bit32.bor(mask, bit32.lshift(1, bit - 1))
			end
		end
		write_u8(cursor, mask)
	elseif type_id == 0x0b then
		write_u32(cursor, value.Number)
	elseif type_id == 0x10 then
		write_f32(cursor, value.X)
		write_f32(cursor, value.Y)
		write_f32(cursor, value.Z)
		write_rotation(cursor, value, true)
	elseif type_id == 0x12 then
		write_string(cursor, tostring(value.EnumType))
		write_u32(cursor, value.Value)
	elseif type_id == 0x14 then
		const offset = reserve(cursor, 6)
		buffer.writei16(cursor.bytes, offset, value.X)
		buffer.writei16(cursor.bytes, offset + 2, value.Y)
		buffer.writei16(cursor.bytes, offset + 4, value.Z)
	elseif type_id == 0x15 or type_id == 0x16 then
		write_u32(cursor, #value.Keypoints)
		for _, keypoint in value.Keypoints do
			if attribute then
				write_f32(cursor, if type_id == 0x15 then keypoint.Envelope else 0)
			end
			write_f32(cursor, keypoint.Time)
			if type_id == 0x15 then
				write_f32(cursor, keypoint.Value)
				if not attribute then
					write_f32(cursor, keypoint.Envelope)
				end
			else
				write_f32(cursor, keypoint.Value.R)
				write_f32(cursor, keypoint.Value.G)
				write_f32(cursor, keypoint.Value.B)
				if not attribute then
					write_f32(cursor, 0)
				end
			end
		end
	elseif type_id == 0x17 then
		write_f32(cursor, value.Min)
		write_f32(cursor, value.Max)
	elseif type_id == 0x19 then
		write_u8(cursor, if value == nil then 0 else 3)
		if value ~= nil then
			for _, component in
				{
					value.Density,
					value.Friction,
					value.Elasticity,
					value.FrictionWeight,
					value.ElasticityWeight,
					value.AcousticAbsorption,
				}
			do
				write_f32(cursor, component)
			end
		end
	elseif type_id == 0x20 then
		if not attribute then
			write_string(cursor, value.Family)
		end
		write_u16(cursor, value.Weight.Value)
		write_u8(cursor, value.Style.Value)
		if attribute then
			write_string(cursor, value.Family)
		end
		write_string(cursor, "")
	else
		error(`unsupported Roblox binary property type 0x{string.format("%02x", type_id)}`)
	end
end

const function read_values(cursor: Cursor, type_id: number, count: number, context: Context): Values
	if type_id == 0x03 then
		return read_words(cursor, count, "int")
	elseif type_id == 0x04 then
		return read_words(cursor, count, "float")
	elseif type_id == 0x0b or type_id == 0x12 or type_id == 0x1c then
		local values: Values = read_words(cursor, count, "uint")
		if type_id ~= 0x12 then
			for index = 1, count do
				if type_id == 0x0b then
					const number: number = values[index]
					values[index] = BrickColor.new(number)
				else
					const value = context.shared_strings[values[index] + 1]
					assert(value ~= nil, "invalid shared string index")
					values[index] = value
				end
			end
		end
		return values
	elseif type_id == 0x13 then
		return read_words(cursor, count, "ref")
	elseif type_id == 0x1b or type_id == 0x21 then
		return read_int64s(cursor, count, type_id == 0x21)
	end
	local values: Values = table.create(count)
	const kinds = COMPONENT_KINDS[type_id]
	if kinds then
		local components = {}
		for index, kind in kinds do
			components[index] = read_words(cursor, count, kind)
		end
		for index = 1, count do
			local parts = {}
			for component = 1, #kinds do
				parts[component] = components[component][index]
			end
			values[index] = from_components(type_id, parts)
		end
	elseif type_id == 0x10 or type_id == 0x1e then
		if type_id == 0x1e then
			assert(read_u8(cursor) == 0x10, "invalid optional CFrame type")
		end
		for index = 1, count do
			values[index] = read_rotation(cursor)
		end
		const x = read_words(cursor, count, "float")
		const y = read_words(cursor, count, "float")
		const z = read_words(cursor, count, "float")
		for index = 1, count do
			values[index] += Vector3.new(x[index], y[index], z[index])
		end
		if type_id == 0x1e then
			assert(read_u8(cursor) == 0x02, "invalid optional CFrame presence type")
			for index = 1, count do
				if read_u8(cursor) == 0 then
					values[index] = nil
				end
			end
		end
	elseif type_id == 0x1a then
		const offset = take(cursor, count * 3)
		for index = 0, count - 1 do
			values[index + 1] = Color3.fromRGB(
				buffer.readu8(cursor.bytes, offset + index),
				buffer.readu8(cursor.bytes, offset + count + index),
				buffer.readu8(cursor.bytes, offset + 2 * count + index)
			)
		end
	elseif type_id == 0x22 then
		const sources = read_words(cursor, count, "int")
		local uris = {}
		for index = 1, read_u32(cursor) do
			uris[index] = read_string(cursor)
		end
		const refs = read_words(cursor, read_u32(cursor), "ref")
		assert(read_u32(cursor) == 0, "external Content objects cannot be restored")
		local uri_index, ref_index = 1, 1
		for index, source in sources do
			if source == 0 then
				values[index] = Content.none
			elseif source == 1 then
				assert(uris[uri_index] ~= nil, "invalid Content URI index")
				values[index] = Content.fromUri(uris[uri_index])
				uri_index += 1
			elseif source == 2 then
				const instance = context.instances[refs[ref_index]]
				assert(instance, "invalid Content object referent")
				values[index] = Content.fromObject(instance)
				ref_index += 1
			else
				error(`unsupported Content source type {source}`)
			end
		end
		assert(uri_index == #uris + 1 and ref_index == #refs + 1, "Content count mismatch")
	else
		for index = 1, count do
			values[index] = read_value(cursor, type_id)
		end
	end
	return values
end

const function write_values(cursor: Cursor, type_id: number, values: Values, count: number, context: Context)
	if type_id == 0x03 then
		write_words(cursor, values, count, "int")
		return
	elseif type_id == 0x04 then
		write_words(cursor, values, count, "float")
		return
	elseif type_id == 0x1b or type_id == 0x21 then
		write_int64s(cursor, values, count, type_id == 0x21)
		return
	end
	const kinds = COMPONENT_KINDS[type_id]
	if kinds then
		local components = {}
		for component = 1, #kinds do
			components[component] = table.create(count)
		end
		for index = 1, count do
			for component, value in get_components(type_id, values[index]) do
				components[component][index] = value
			end
		end
		for component, kind in kinds do
			write_words(cursor, components[component], count, kind)
		end
	elseif type_id == 0x0b or type_id == 0x12 or type_id == 0x13 or type_id == 0x1c then
		local words = table.create(count)
		for index = 1, count do
			const value = values[index]
			if type_id == 0x0b then
				words[index] = value.Number
			elseif type_id == 0x12 then
				words[index] = value.Value
			elseif type_id == 0x13 then
				words[index] = context.referents[value] or -1
			else
				local shared_index = context.shared_indices[value]
				if shared_index == nil then
					shared_index = #context.shared_strings
					context.shared_indices[value] = shared_index
					table.insert(context.shared_strings, value)
				end
				words[index] = shared_index
			end
		end
		write_words(cursor, words, count, if type_id == 0x13 then "ref" else "uint")
	elseif type_id == 0x10 or type_id == 0x1e then
		if type_id == 0x1e then
			write_u8(cursor, 0x10)
		end
		local positions = table.create(count)
		for index = 1, count do
			const value = values[index] or CFrame.identity
			write_rotation(cursor, value)
			positions[index] = value.Position
		end
		write_values(cursor, 0x0e, positions, count, context)
		if type_id == 0x1e then
			write_u8(cursor, 0x02)
			for index = 1, count do
				write_u8(cursor, if values[index] ~= nil then 1 else 0)
			end
		end
	elseif type_id == 0x1a then
		const offset = reserve(cursor, count * 3)
		for index = 1, count do
			for component, value in { values[index].R, values[index].G, values[index].B } do
				buffer.writeu8(
					cursor.bytes,
					offset + (component - 1) * count + index - 1,
					math.clamp(math.round(value * 255), 0, 255)
				)
			end
		end
	elseif type_id == 0x22 then
		local sources, uris, refs = {}, {}, {}
		for index = 1, count do
			const value = values[index]
			if value.SourceType == Enum.ContentSourceType.None then
				sources[index] = 0
			elseif value.SourceType == Enum.ContentSourceType.Uri then
				sources[index] = 1
				table.insert(uris, value.Uri)
			else
				const referent = context.referents[value.Object]
				assert(referent ~= nil, "Content object is outside the serialized model")
				sources[index] = 2
				table.insert(refs, referent)
			end
		end
		write_words(cursor, sources, count, "int")
		write_u32(cursor, #uris)
		for _, uri in uris do
			write_string(cursor, uri)
		end
		write_u32(cursor, #refs)
		write_words(cursor, refs, #refs, "ref")
		write_u32(cursor, 0)
	else
		for index = 1, count do
			write_value(cursor, type_id, values[index])
		end
	end
end

const ATTRIBUTE_IDS: { [string]: number } = {
	string = 0x02,
	boolean = 0x03,
	number = 0x06,
	UDim = 0x09,
	UDim2 = 0x0a,
	BrickColor = 0x0e,
	Color3 = 0x0f,
	Vector2 = 0x10,
	Vector3 = 0x11,
	CFrame = 0x14,
	EnumItem = 0x15,
	NumberSequence = 0x17,
	ColorSequence = 0x19,
	NumberRange = 0x1b,
	Rect = 0x1c,
	Font = 0x21,
}
-- Attribute type IDs map to property types, but use a non-interleaved layout.
const ATTRIBUTE_TYPES: { [number]: number } = {
	[0x02] = 0x01,
	[0x03] = 0x02,
	[0x04] = 0x03,
	[0x05] = 0x04,
	[0x06] = 0x05,
	[0x09] = 0x06,
	[0x0a] = 0x07,
	[0x0e] = 0x0b,
	[0x0f] = 0x0c,
	[0x10] = 0x0d,
	[0x11] = 0x0e,
	[0x14] = 0x10,
	[0x15] = 0x12,
	[0x17] = 0x15,
	[0x19] = 0x16,
	[0x1b] = 0x17,
	[0x1c] = 0x18,
	[0x21] = 0x20,
}

const function serialize_attributes(attributes: { [string]: any }): string
	local names = {}
	for name in attributes do
		table.insert(names, name)
	end
	if #names == 0 then
		return ""
	end
	table.sort(names)
	local cursor = { bytes = buffer.create(64), position = 0 }
	write_u32(cursor, #names)
	for _, name in names do
		const value = attributes[name]
		const type_id = ATTRIBUTE_IDS[typeof(value)]
		assert(type_id ~= nil, `unsupported attribute type {typeof(value)}`)
		write_string(cursor, name)
		write_u8(cursor, type_id)
		const property_type = ATTRIBUTE_TYPES[type_id]
		const kinds = COMPONENT_KINDS[property_type]
		if kinds then
			local parts = get_components(property_type, value)
			if property_type == 0x07 then
				parts[2], parts[3] = parts[3], parts[2]
			end
			for index, part in parts do
				if (property_type == 0x06 and index == 2) or (property_type == 0x07 and index % 2 == 0) then
					const offset = reserve(cursor, 4)
					buffer.writei32(cursor.bytes, offset, part)
				else
					write_f32(cursor, part)
				end
			end
		else
			write_value(cursor, property_type, value, true)
		end
	end
	return buffer.tostring(finish(cursor))
end

const function deserialize_attributes(value: string): { [string]: any }
	local attributes: { [string]: any } = {}
	if #value == 0 then
		return attributes
	end
	local cursor = { bytes = buffer.fromstring(value), position = 0 }
	const count = read_u32(cursor)
	assert(count <= #value / 5, "invalid attribute count")
	for _ = 1, count do
		const name = read_string(cursor)
		const type_id = read_u8(cursor)
		local attribute: any = nil
		const property_type = ATTRIBUTE_TYPES[type_id]
		assert(property_type ~= nil, `unsupported attribute type 0x{string.format("%02x", type_id)}`)
		const kinds = COMPONENT_KINDS[property_type]
		if kinds then
			local parts = {}
			for index = 1, #kinds do
				if (property_type == 0x06 and index == 2) or (property_type == 0x07 and index % 2 == 0) then
					parts[index] = buffer.readi32(cursor.bytes, take(cursor, 4))
				else
					parts[index] = read_f32(cursor)
				end
			end
			if property_type == 0x07 then
				parts[2], parts[3] = parts[3], parts[2]
			end
			attribute = from_components(property_type, parts)
		else
			attribute = read_value(cursor, property_type, true)
		end
		attributes[name] = attribute
	end
	assert(cursor.position == #value, "unexpected trailing attribute data")
	return attributes
end

const function new_context(): Context
	return { referents = {}, instances = {}, shared_strings = {}, shared_indices = {} }
end

return {
	reserve = reserve,
	finish = finish,
	read_u8 = read_u8,
	read_u32 = read_u32,
	write_u8 = write_u8,
	write_u32 = write_u32,
	write_string = write_string,
	get_enum = get_enum,
	read_collision_fidelity = read_collision_fidelity,
	read_words = read_words,
	write_words = write_words,
	read_values = read_values,
	write_values = write_values,
	serialize_attributes = serialize_attributes,
	deserialize_attributes = deserialize_attributes,
	new_context = new_context,
}
