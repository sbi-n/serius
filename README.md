# serius
Roblox binary model serialization using `buffer` and `ReflectionService`.

```luau
const Serius = require("./serius")

local bytes = Serius.serialize_model(workspace.Model)
local roots = Serius.deserialize_model(bytes)
for _, instance in roots do
	instance.Parent = workspace
end
```

`serialize_model(model: Instance | { Instance }): buffer` includes the supplied
roots and their descendants. Duplicate and overlapping roots are included once.
Instance references outside the serialized hierarchy become `nil`.

`deserialize_model(bytes: buffer): { Instance }` returns detached roots with their
properties, descendants, internal references, attributes, and tags restored.
MeshParts with mesh content are created concurrently with `AssetService:CreateMeshPartAsync`
before properties and references are restored, preserving their mesh IDs and
collision, render, and fluid fidelity settings. This function may yield until all
mesh requests finish; the caller must have access to the referenced assets.
For engine-generated RBXM, collision fidelity is recovered from physical config
headers (versions 0, 7, and 8) when no explicit property is present.
Failed imports wait for outstanding requests and destroy the instances they created.

The reader extends [Bolt's rbxm.luau](https://github.com/unityjaeger/Bolt/blob/main/BoltMesh/Modules/rbxm.luau)
and accepts uncompressed, LZ4, and Zstd chunks. The writer emits uncompressed RBXM.
The original `read_model`, `read_shared_strings`, and `internal` exports remain available.

Property discovery calls `ReflectionService` for each operation without caching
class or property metadata; access follows the calling script's capabilities.
Properties that Luau cannot both read and write are omitted,
including engine identifiers, internal mesh data, and script source when source
access is unavailable. MeshPart geometry is reloaded from its mesh asset rather
than embedded in the buffer. Union/Intersect/Negate geometry is not restored;
only their accessible properties and hierarchy are recreated.
Services and other non-creatable classes are rejected.

`src/init.luau` provides the public API and restores instance hierarchies.
`src/Rbxm.luau` reads and writes the RBXM container, `src/Values.luau` handles
binary values and attributes, and `src/Reflection.luau` handles property discovery
and access.

Build the ModuleScript with `rojo build -o serius.rbxm`.
