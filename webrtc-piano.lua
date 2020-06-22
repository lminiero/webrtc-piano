-- Note: this example depends on lua-json to do JSON processing
-- (http://luaforge.net/projects/luajson/)
json = require('json')
-- Let's also use our ugly stdout logger just for the fun of it: to add
-- some color to the text we use the ansicolors library
-- (https://github.com/kikito/ansicolors.lua)
colors = require('ansicolors')
logger = require('janus-logger')
-- We need midialsa as well
ALSA = require 'midialsa'

-- Plugin details
name = 'webrtc-piano.lua'
logger.prefix(colors('[%{blue}' .. name .. '%{reset}]'))
logger.print('Loading...')

-- State and properties
sessions = {}
tasks = {}
datas = {}

-- Helper to get local path
function script_path()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*/)")
end

-- SDP template
sdpTemplate= "v=0\r\n" ..
		"o=- 0 0 IN IP4 127.0.0.1\r\n" ..
		"s=Janus WebRTC Piano\r\n" ..
		"t=0 0\r\n" ..
		"m=application 1 DTLS/SCTP webrtc-datachannel\r\n" ..
		"c=IN IP4 1.1.1.1\r\n" ..
		"a=sctp-port:5000\r\n"

-- Methods
function init()
	-- This is where we initialize the plugin, for static properties
	logger.print("Initialized")
	-- Connect the MIDI client
	ALSA.client('Janus WebRTC Piano client', 0, 1, false)
	ALSA.connectfrom(0, 14, 0)
	ALSA.connectto(1, 'Midi Through')
	ALSA.start()
end

function destroy()
	-- This is where we deinitialize the plugin, when Janus shuts down
	logger.print("Deinitialized")
end

function createSession(id)
	-- Keep track of a new session
	logger.print("Created new session: " .. id)
	sessions[id] = { id = id, lua = name }
end

function destroySession(id)
	-- A Janus plugin session has gone
	logger.print("Destroyed session: " .. id)
	hangupMedia(id)
	sessions[id] = nil
end

function querySession(id)
	-- Return info on a session
	logger.print("Queried session: " .. id)
	local s = sessions[id]
	if s == nil then
		return nil
	end
	info = { script = s["lua"], id = s["id"], name = s["name"], color = s["color"] }
	infojson = json.encode(info)
	return infojson
end

function handleMessage(id, tr, msg, jsep)
	-- Handle a message, synchronously or asynchronously, and return
	-- something accordingly: if it's the latter, we'll do a coroutine
	logger.print("Handling message for session: " .. id)
	local s = sessions[id]
	if s == nil then
		return -1, "Session not found"
	end
	-- Decode the message JSON string to a table
	local msgT = json.decode(msg)
	-- We only support request:"setup" and request:"ack" here
	if msgT["request"] == "setup" then
		-- We need a new coroutine here
		async = coroutine.create(function(id, tr, comsg, cojsep)
			-- We'll only execute this when the scheduler resumes the task
			logger.print("Handling async message for session: " .. id)
			-- Prepare an offer
			local event = { event = "success" }
			eventjson = json.encode(event)
			local offer = { type = "offer", sdp = sdpTemplate }
			jsep = json.encode(offer)
			pushEvent(id, tr, eventjson, jsep)
		end)
		-- Enqueue it: the scheduler will resume it later
		tasks[#tasks+1] = { co = async, id = id, tr = tr, msg = msgT, jsep = nil }
		-- Return explaining that this is will be handled asynchronously
		pokeScheduler()
		return 1, nil
	elseif msgT["request"] == "ack" then
		if jsep ~= nil then
			local response = { response = "error", error = "Missing answer" }
			responsejson = json.encode(response)
			return 0, responsejson
		end
		local response = { response = "response", result = "success" }
		responsejson = json.encode(response)
		return 0, responsejson
	else
		local response = { response = "error", error = "Unsupported request" }
		responsejson = json.encode(response)
		return 0, responsejson
	end
end

function setupMedia(id)
	-- WebRTC is now available
	logger.print("WebRTC PeerConnection is up for session: " .. id)
end

function hangupMedia(id)
	-- WebRTC not available anymore
	logger.print("WebRTC PeerConnection is down for session: " .. id)
	local s = sessions[id]
	if s == nil or s.name == nil then
		return
	end
	-- Notify everyone
	local n = { event = "leave", id = id }
	local njson = json.encode(n)
	for index,p in pairs(sessions) do
		if p ~= nil and p.id ~= id then
			relayTextData(p.id, njson, string.len(njson))
		end
	end
end

function incomingTextData(id, data, length)
	-- Incoming data channel message: parse and handle
	logger.print("Got data channel message: " .. id)
	logger.print("  -- " .. data)
	-- Handle the data asynchronously
	async = coroutine.create(function(id, data, length)
		-- We'll only execute this when the scheduler resumes the task
		logger.print("Handling async data for session: " .. id)
		logger.print("  -- " .. data)
		local s = sessions[id]
		if s == nil then
			return
		end
		-- Are we playing or stopping a note?
		local cmd = json.decode(data)
		local action = cmd["action"]
		if action == nil then
			local response = { response = "error", error = "Missing action" }
			local responsejson = json.encode(response)
			relayTextData(id, responsejson, string.len(responsejson))
		end
		if action == "register" then
			-- We require a name and a color
			local name = cmd["name"]
			if name == nil then
				local response = { response = "error", error = "Missing name" }
				local responsejson = json.encode(response)
				relayTextData(id, responsejson, string.len(responsejson))
			end
			local color = cmd["color"]
			if color == nil then
				local response = { response = "error", error = "Missing color" }
				local responsejson = json.encode(response)
				relayTextData(id, responsejson, string.len(responsejson))
			end
			s.name = name
			s.color = color
			-- Notify everyone
			local n = { event = "join", id = id, name = name, color = color }
			local njson = json.encode(n)
			for index,p in pairs(sessions) do
				if p ~= nil then
					relayTextData(p.id, njson, string.len(njson))
					-- Notify about this player too
					if p.id ~= id then
						local np = { event = "join", id = p.id, name = p.name, color = p.color }
						local npjson = json.encode(np)
						relayTextData(id, npjson, string.len(npjson))
					end
				end
			end
			-- Send a response
			local response = { response = "success" }
			local responsejson = json.encode(response)
			relayTextData(id, responsejson, string.len(responsejson))
		elseif action == "play" then
			-- We require a note
			local note = cmd["note"]
			if note == nil then
				local response = { response = "error", error = "Missing note" }
				local responsejson = json.encode(response)
				relayTextData(id, responsejson, string.len(responsejson))
			end
			-- Queue an ALSA note event
			local event = ALSA.noteonevent(0, note, 100, 0)
			ALSA.output(event)
			-- Notify everyone
			local n = { event = "play", note = note, name = s.name, color = s.color }
			local njson = json.encode(n)
			for index,p in pairs(sessions) do
				if p ~= nil and p.id ~= id then
					relayTextData(p.id, njson, string.len(njson))
				end
			end
			-- Send a response
			local response = { response = "success" }
			local responsejson = json.encode(response)
			relayTextData(id, responsejson, string.len(responsejson))
		elseif action == "stop" then
			-- We require a note
			local note = cmd["note"]
			if note == nil then
				local response = { response = "error", error = "Missing note" }
				local responsejson = json.encode(response)
				relayTextData(id, responsejson, string.len(responsejson))
			end
			-- Queue an ALSA note event
			local event = ALSA.noteoffevent(0, note, 100, 0)
			ALSA.output(event)
			-- Notify everyone
			local n = { event = "stop", note = note, name = s.name, color = s.color }
			local njson = json.encode(n)
			for index,p in pairs(sessions) do
				if p ~= nil and p.id ~= id then
					relayTextData(p.id, njson, string.len(njson))
				end
			end
			-- Send a response
			local response = { response = "success" }
			local responsejson = json.encode(response)
			relayTextData(id, responsejson, string.len(responsejson))
		else
			local response = { response = "error", error = "Invalid action" }
			local responsejson = json.encode(response)
			relayTextData(id, responsejson, string.len(responsejson))
		end
	end)
	-- Enqueue it: the scheduler will resume it later
	datas[#datas+1] = { co = async, id = id, data = data, length = length }
	pokeScheduler()
end

function resumeScheduler()
	-- This is the function responsible for resuming coroutines associated
	-- with asynchronous requests: if you're handling async stuff yourself,
	-- you're free not to use this and just return, but the C Lua plugin
	-- expects this method to exist so it MUST be present, even if empty
	logger.print("Resuming coroutines")
	for index,task in ipairs(tasks) do
		coroutine.resume(task.co, task.id, task.tr, task.msg, task.jsep)
	end
	tasks = {}
	for index,task in ipairs(datas) do
		coroutine.resume(task.co, task.id, task.data, task.length)
	end
	logger.print("Coroutines resumed")
	datas = {}
end

-- Helper for logging tables
-- https://stackoverflow.com/a/27028488
function dumpTable(o)
	if type(o) == 'table' then
		local s = '{ '
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. dumpTable(v) .. ','
		end
		return s .. '} '
	else
		return tostring(o)
	end
end

-- Done
logger.print("Loaded")
