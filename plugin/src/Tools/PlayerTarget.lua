-- Usernames take priority; display names are only usable when unambiguous.
local PlayerTarget = {}

function PlayerTarget.resolve(players, name)
	for _, player in ipairs(players) do
		if player.Name == name then
			return player
		end
	end
	local match = nil
	for _, player in ipairs(players) do
		if player.DisplayName == name then
			if match then
				return nil,
					("Several players use the display name '%s'; specify their unique player Name."):format(name)
			end
			match = player
		end
	end
	if match then
		return match
	end
	return nil, ("No player named '%s' is in this playtest."):format(name)
end

return PlayerTarget
