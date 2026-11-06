--!strict
--!optimize 2

-- Chunk layout and LZ4 handling follow BoltMesh/Modules/rbxm.luau:
-- https://github.com/unityjaeger/Bolt/blob/main/BoltMesh/Modules/rbxm.luau
-- Binary format: https://dom.rojo.space/binary.html
--[[
MIT License

Copyright (c) 2026 unityjaeger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

const EncodingService = game:GetService("EncodingService")

const Values = require("./values")

export type ModelClass = {
	name: string,
	instance_count: number,
	referents: { number },
	properties: { { name: string, type_id: number, content: buffer, offset: number } },
	-- per property name, one value per instance of the class in file order
	-- only String properties (Name among them) are decoded
	strings: { [string]: { string } },
	-- per property name, one 1-based index into `shared_strings` per instance
	shared_string_indices: { [string]: { number } },
}

export type Model = {
	shared_strings: { buffer },
	classes: { [number]: ModelClass },
	parents: { [number]: number },
	parent_order: { number },
}

const SIGNATURE = "<roblox!\137\255\r\n\26\n"
const ZSTD_MAGIC = "\40\181\47\253"
const TYPE_STRING = 1
const TYPE_SHARED_STRING = 28

const function native_decompress_zstd(frame: buffer, uncompressed_length: number): buffer
	-- EncodingService requires a frame content size; RBXM also accepts frames without one.
	if EncodingService:GetDecompressedBufferSize(frame, Enum.CompressionAlgorithm.Zstd) == nil then
		const descriptor = buffer.readu8(frame, 4)
		assert(bit32.band(descriptor, 0xe0) == 0, "invalid Zstd frame content size")
		const dictionary_length = ({ 0, 1, 2, 4 })[bit32.band(descriptor, 3) + 1]
		const offset = 6 + dictionary_length
		assert(offset <= buffer.len(frame), "truncated Zstd frame header")
		local sized = buffer.create(buffer.len(frame) + 4)
		buffer.copy(sized, 0, frame, 0, offset)
		buffer.writeu8(sized, 4, bit32.bor(descriptor, 0x80))
		buffer.writeu32(sized, offset, uncompressed_length)
		buffer.copy(sized, offset + 4, frame, offset, buffer.len(frame) - offset)
		frame = sized
	end
	return EncodingService:DecompressBuffer(frame, Enum.CompressionAlgorithm.Zstd)
end

-- one LZ4 block
const function decompress_lz4_block(source: buffer, offset: number, length: number, output_length: number): buffer
	local output = buffer.create(output_length)
	local input_position = offset
	local input_end = offset + length
	local output_position = 0

	while input_position < input_end do
		local token = buffer.readu8(source, input_position)
		input_position += 1

		local literal_length = bit32.rshift(token, 4)
		if literal_length == 15 then
			local extra = 255
			while extra == 255 do
				extra = buffer.readu8(source, input_position)
				input_position += 1
				literal_length += extra
			end
		end

		buffer.copy(output, output_position, source, input_position, literal_length)

		output_position += literal_length
		input_position += literal_length
		if input_position >= input_end then
			break
		end

		local match_offset = buffer.readu16(source, input_position)
		input_position += 2

		assert(match_offset > 0 and match_offset <= output_position, "corrupt LZ4 block: match offset out of range")

		local match_length = bit32.band(token, 15)
		if match_length == 15 then
			local extra = 255
			while extra == 255 do
				extra = buffer.readu8(source, input_position)
				input_position += 1
				match_length += extra
			end
		end
		match_length += 4

		-- a match may overlap its own output, copying one offset's worth at a time replicates the pattern the way a byte loop would
		local match_position = output_position - match_offset
		while match_length > match_offset do
			buffer.copy(output, output_position, output, match_position, match_offset)
			output_position += match_offset
			match_length -= match_offset
		end

		buffer.copy(output, output_position, output, match_position, match_length)
		output_position += match_length
	end

	assert(output_position == output_length, "corrupt LZ4 block: decompressed length mismatch")

	return output
end

const function read_chunk_content(
	bytes: buffer,
	position: number,
	compressed_length: number,
	uncompressed_length: number,
	decompress_zstd: ((buffer) -> buffer)?
): buffer
	if compressed_length == 0 then
		local content = buffer.create(uncompressed_length)
		buffer.copy(content, 0, bytes, position, uncompressed_length)
		return content
	elseif compressed_length >= 4 and buffer.readstring(bytes, position, 4) == ZSTD_MAGIC then
		local frame = buffer.create(compressed_length)
		buffer.copy(frame, 0, bytes, position, compressed_length)
		if decompress_zstd == nil then
			return native_decompress_zstd(frame, uncompressed_length)
		end
		return (decompress_zstd :: (buffer) -> buffer)(frame)
	end

	return decompress_lz4_block(bytes, position, compressed_length, uncompressed_length)
end

const function read_shared_string_chunk(content: buffer, shared_strings: { buffer })
	local count = buffer.readu32(content, 4)
	local offset = 8

	for _ = 1, count do
		local string_length = buffer.readu32(content, offset + 16)
		local value = buffer.create(string_length)
		buffer.copy(value, 0, content, offset + 20, string_length)
		table.insert(shared_strings, value)
		offset += 20 + string_length
	end
end

const function read_instance_chunk(content: buffer, classes: { [number]: ModelClass })
	local class_id = buffer.readu32(content, 0)
	local name_length = buffer.readu32(content, 4)
	assert(classes[class_id] == nil, "duplicate Roblox binary model class ID")

	classes[class_id] = {
		name = buffer.readstring(content, 8, name_length),
		-- u8 object format sits between the name and the count
		instance_count = buffer.readu32(content, 9 + name_length),
		referents = {},
		properties = {},
		strings = {},
		shared_string_indices = {},
	}
	local class = classes[class_id]
	class.referents = Values.read_words({ bytes = content, position = 13 + name_length }, class.instance_count, "ref")
end

const function read_property_chunk(content: buffer, classes: { [number]: ModelClass })
	local class_id = buffer.readu32(content, 0)
	local name_length = buffer.readu32(content, 4)
	local property_name = buffer.readstring(content, 8, name_length)
	local type_id = buffer.readu8(content, 8 + name_length)
	local offset = 9 + name_length
	local class = classes[class_id]

	assert(class ~= nil, "Roblox binary model property chunk precedes its instance chunk")

	local count = class.instance_count
	table.insert(class.properties, { name = property_name, type_id = type_id, content = content, offset = offset })
	if type_id == TYPE_STRING then
		local values = table.create(count) :: { string }
		for index = 1, count do
			local value_length = buffer.readu32(content, offset)
			values[index] = buffer.readstring(content, offset + 4, value_length)
			offset += 4 + value_length
		end

		class.strings[property_name] = values
	elseif type_id == TYPE_SHARED_STRING then
		local values = Values.read_words({ bytes = content, position = offset }, count, "uint")
		for index, value in values do
			values[index] = value + 1
		end

		class.shared_string_indices[property_name] = values
	end
end

const function read_parent_chunk(content: buffer, model: Model)
	assert(#model.parent_order == 0, "duplicate Roblox binary model parent chunk")
	local cursor = { bytes = content, position = 0 }
	assert(Values.read_u8(cursor) == 0, "unsupported Roblox binary model parent version")
	local count = Values.read_u32(cursor)
	local children = Values.read_words(cursor, count, "ref")
	local parents = Values.read_words(cursor, count, "ref")
	for index, child in children do
		assert(model.parents[child] == nil, "duplicate Roblox binary model parent entry")
		model.parents[child] = parents[index]
	end
	model.parent_order = children
end

-- the shared strings of the model in SSTR order, each as its own buffer, and per class the String and SharedString properties of its instances
const function read_model(bytes: buffer, decompress_zstd: ((buffer) -> buffer)?): Model
	local length = buffer.len(bytes)
	assert(length >= 32 and buffer.readstring(bytes, 0, 14) == SIGNATURE, "not a Roblox binary model")
	assert(buffer.readu16(bytes, 14) == 0, "unsupported Roblox binary model version")

	local model: Model = {
		shared_strings = {},
		classes = {},
		parents = {},
		parent_order = {},
	}

	local position = 32
	while true do
		assert(position + 16 <= length, "truncated Roblox binary model")
		local name = buffer.readstring(bytes, position, 4)
		local compressed_length = buffer.readu32(bytes, position + 4)
		local uncompressed_length = buffer.readu32(bytes, position + 8)
		position += 16

		if name == "END\0" then
			assert(
				compressed_length == 0
					and uncompressed_length == 9
					and position + 9 <= length
					and buffer.readstring(bytes, position, 9) == "</roblox>",
				"invalid Roblox binary model end chunk"
			)
			break
		end

		local data_length = if compressed_length == 0 then uncompressed_length else compressed_length
		assert(position + data_length <= length, "truncated Roblox binary model chunk")

		if name == "SSTR" or name == "INST" or name == "PROP" or name == "PRNT" then
			local content = read_chunk_content(bytes, position, compressed_length, uncompressed_length, decompress_zstd)
			assert(buffer.len(content) == uncompressed_length, "Roblox binary model decompressed length mismatch")
			if name == "SSTR" then
				read_shared_string_chunk(content, model.shared_strings)
			elseif name == "INST" then
				read_instance_chunk(content, model.classes)
			elseif name == "PROP" then
				read_property_chunk(content, model.classes)
			else
				read_parent_chunk(content, model)
			end
		end
		position += data_length
	end

	return model
end

const function read_shared_strings(bytes: buffer, decompress_zstd: ((buffer) -> buffer)?): { buffer }
	return read_model(bytes, decompress_zstd).shared_strings
end

const function write_chunk(cursor: Values.Cursor, name: string, content: buffer)
	const length = buffer.len(content)
	const position = Values.reserve(cursor, 16 + length)
	buffer.writestring(cursor.bytes, position, name)
	buffer.writeu32(cursor.bytes, position + 4, 0)
	buffer.writeu32(cursor.bytes, position + 8, length)
	buffer.writeu32(cursor.bytes, position + 12, 0)
	buffer.copy(cursor.bytes, position + 16, content)
end

const function write_model(
	instance_chunks: { buffer },
	property_chunks: { buffer },
	shared_strings: { string },
	children: { number },
	parent_refs: { number }
): buffer
	local output = { bytes = buffer.create(64), position = 32 }
	buffer.writestring(output.bytes, 0, SIGNATURE)
	buffer.writeu32(output.bytes, 16, #instance_chunks)
	buffer.writeu32(output.bytes, 20, #children)
	if #shared_strings > 0 then
		local content = { bytes = buffer.create(64), position = 0 }
		Values.write_u32(content, 0)
		Values.write_u32(content, #shared_strings)
		for _, value in shared_strings do
			Values.reserve(content, 16) -- Studio does not require SharedString MD5 hashes
			Values.write_string(content, value)
		end
		write_chunk(output, "SSTR", Values.finish(content))
	end
	for _, content in instance_chunks do
		write_chunk(output, "INST", content)
	end
	for _, content in property_chunks do
		write_chunk(output, "PROP", content)
	end
	local parents = { bytes = buffer.create(64), position = 0 }
	Values.write_u8(parents, 0)
	Values.write_u32(parents, #children)
	Values.write_words(parents, children, #children, "ref")
	Values.write_words(parents, parent_refs, #parent_refs, "ref")
	write_chunk(output, "PRNT", Values.finish(parents))
	write_chunk(output, "END\0", buffer.fromstring("</roblox>"))
	return Values.finish(output)
end

local internal = {
	decompress_lz4_block = decompress_lz4_block,
}
table.freeze(internal)

return {
	read_model = read_model,
	write_model = write_model,
	read_shared_strings = read_shared_strings,
	internal = internal,
}
