return function()
	local Error = require(script.Parent.Error)

	describe("fromRobloxErrorString", function()
		it("should recognize HTTP being disabled", function()
			local err = Error.fromRobloxErrorString("Http requests are not enabled. Enable via game settings")
			expect(err.type).to.equal(Error.Kind.HttpNotEnabled)
		end)

		it("should recognize a timeout", function()
			local err = Error.fromRobloxErrorString("HttpError: Timedout")
			expect(err.type).to.equal(Error.Kind.Timeout)
		end)

		it("should recognize every flavor of unreachable server", function()
			-- NetFail is what Roblox returns when nothing is listening on a local
			-- port, which is the everyday case of the VibeStarter app not running.
			for _, raw in ipairs({ "HttpError: ConnectFail", "HttpError: NetFail", "HttpError: DnsResolve" }) do
				local err = Error.fromRobloxErrorString(raw)
				expect(err.type).to.equal(Error.Kind.ConnectFailed)
			end
		end)

		it("should not claim the server is unreachable when TLS fails", function()
			local err = Error.fromRobloxErrorString("HttpError: SslConnectFail")
			expect(err.type).to.equal(Error.Kind.Unknown)
		end)

		it("should fall back to Unknown with the raw message", function()
			local err = Error.fromRobloxErrorString("HttpError: Aborted")
			expect(err.type).to.equal(Error.Kind.Unknown)
			expect(string.find(err.message, "HttpError: Aborted", 1, true)).to.be.ok()
		end)
	end)

	describe("messages", function()
		it("should not tell VibeStarter users to run a Rojo server", function()
			-- The plugin is driven by the VibeStarter app; `rojo serve` is never a
			-- step a user takes, so advising it sent people looking for a command
			-- that does not exist for them.
			for _, kind in pairs(Error.Kind) do
				expect(string.find(kind.message:lower(), "rojo") == nil).to.equal(true)
			end
		end)
	end)
end
