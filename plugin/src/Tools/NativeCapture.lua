-- Capture pixels in Studio. No window matching, input synthesis or OS reader.
local ClientProxy = require(script.Parent.ClientProxy)
local Capture = {}
local MAX_PIXELS = 1024 * 1024

-- Only the edit plugin can read temporary textures into EditableImage.
function Capture.acquire(args)
	assert(
		not game:GetService("RunService"):IsRunMode(),
		"STUDIO_CAPTURE_REQUIRES_PLAY: Run has no capture client. Use Play for screenshots."
	)
	if args.client then
		local source = string.format(
			"return require(game:GetService('ReplicatedStorage')[%q].CaptureView).acquire(%s)",
			ClientProxy.FOLDER_NAME,
			args.operation and string.format("%q", args.operation) or "nil"
		)
		local result, why = ClientProxy.call(source, script.Parent.Runtime, script.Parent.Query, args.player)
		assert(result, tostring(why))
		return result
	end
	return require(script.Parent.CaptureView).acquire(args.operation)
end

-- Base64 has a bounded wire size and needs no additional Roblox capability.
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
	local ok, encoded = pcall(function()
		return game:GetService("EncodingService"):Base64Encode(data)
	end)
	if ok then
		return buffer.tostring(encoded)
	end
	local n = buffer.len(data)
	local out = buffer.create(math.ceil(n / 3) * 4)
	local dst = 0
	for i = 0, n - 1, 3 do
		local a = buffer.readu8(data, i)
		local b = i + 1 < n and buffer.readu8(data, i + 1) or 0
		local c = i + 2 < n and buffer.readu8(data, i + 2) or 0
		local value = a * 65536 + b * 256 + c
		buffer.writeu8(out, dst, string.byte(alphabet, math.floor(value / 262144) % 64 + 1))
		buffer.writeu8(out, dst + 1, string.byte(alphabet, math.floor(value / 4096) % 64 + 1))
		buffer.writeu8(out, dst + 2, i + 1 < n and string.byte(alphabet, math.floor(value / 64) % 64 + 1) or 61)
		buffer.writeu8(out, dst + 3, i + 2 < n and string.byte(alphabet, value % 64 + 1) or 61)
		dst += 4
	end
	return buffer.tostring(out)
end

function Capture.pixels(args)
	assert(type(args.uri) == "string" and string.match(args.uri, "^rbxtemp://"), "Invalid capture URI")
	local image = game:GetService("AssetService"):CreateEditableImageAsync(Content.fromUri(args.uri))
	assert(image, "STUDIO_CAPTURE_MEMORY: EditableImage budget exhausted")
	-- No yields between allocation and destruction: timeout cancellation cannot
	-- strand an allocated EditableImage while reading or encoding its pixels.
	local resized = nil
	local ok, result = pcall(function()
		local size = image.Size
		local sourceSize = size
		if size.X > 1024 or size.Y > 1024 then
			local scale = 1024 / math.max(size.X, size.Y)
			size = Vector2.new(math.max(1, math.floor(size.X * scale)), math.max(1, math.floor(size.Y * scale)))
			resized = game:GetService("AssetService"):CreateEditableImage({ Size = size })
			assert(resized, "STUDIO_CAPTURE_MEMORY: Cannot allocate resized image")
			resized:DrawImageTransformed(
				Vector2.zero,
				Vector2.new(size.X / sourceSize.X, size.Y / sourceSize.Y),
				0,
				image,
				{ CombineType = Enum.ImageCombineType.Overwrite, PivotPoint = Vector2.zero }
			)
		end
		assert(size.X * size.Y <= MAX_PIXELS, "STUDIO_CAPTURE_SIZE: Image exceeds transport budget")
		local pixels = (resized or image):ReadPixelsBuffer(Vector2.zero, size)
		local compressed, packed = pcall(function()
			return game:GetService("EncodingService"):CompressBuffer(pixels, Enum.CompressionAlgorithm.Zstd, 1)
		end)
		local useCompressed = compressed and buffer.len(packed) < buffer.len(pixels)
		return {
			width = size.X,
			height = size.Y,
			sourceWidth = sourceSize.X,
			sourceHeight = sourceSize.Y,
			rgba = base64(useCompressed and packed or pixels),
			compression = useCompressed and "zstd" or "none",
		}
	end)
	if resized then
		resized:Destroy()
	end
	image:Destroy()
	assert(ok, tostring(result))
	return result
end
return Capture
