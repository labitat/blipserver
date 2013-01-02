#!/usr/bin/env lem
--
-- This file is part of blipserver.
-- Copyright 2011 Emil Renner Berthing
--
-- blipserver is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version.
--
-- blipserver is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with blipserver.  If not, see <http://www.gnu.org/licenses/>.
--

local utils        = require 'lem.utils'
local streams      = require 'lem.streams'
local postgres     = require 'lem.postgres'
local qpostgres    = require 'lem.postgres.queued'
local hathaway     = require 'lem.hathaway'
local gettimeofday = require 'gettimeofday'

local assert = assert
local format = string.format
local tonumber = tonumber

local get_blip, put_blip
do
	local thisthread, suspend, resume
		= utils.thisthread, utils.suspend, utils.resume
	local queue, n = {}, 0

	function get_blip()
		n = n + 1;
		queue[n] = thisthread()

		return suspend()
	end

	function put_blip(now, ms)
		print(now, ms, n)
		for i = 1, n do
			resume(queue[i], now, ms)
			queue[i] = nil
		end

		n = 0
	end
end

utils.spawn(function()
	local serial = assert(streams.open('/dev/serial/blipduino', 'r'))
	local db = assert(postgres.connect('user=powermeter dbname=powermeter'))
	assert(db:prepare('put', 'INSERT INTO readings VALUES ($1, $2)'))

	-- discard first two readings
	assert(serial:read('*l'))
	assert(serial:read('*l'))

	while true do
		local ms = assert(serial:read('*l'))
		local now = format('%0.f', gettimeofday() * 1000)

		put_blip(now, ms)
		assert(db:run('put', now, ms))
	end
end)

local function sendfile(content, path)
	return function(req, res)
		res.headers['Content-Type'] = content
		res.file = path
	end
end

hathaway.import()

GET('/',               sendfile('text/html; charset=UTF-8',       'index.html'))
GET('/index.html',     sendfile('text/html; charset=UTF-8',       'index.html'))
GET('/jquery.js',      sendfile('text/javascript; charset=UTF-8', 'jquery.js'))
GET('/jquery.flot.js', sendfile('text/javascript; charset=UTF-8', 'jquery.flot.js'))
GET('/excanvas.js',    sendfile('text/javascript; charset=UTF-8', 'excanvas.js'))
GET('/favicon.ico',    sendfile('image/x-icon',                   'favicon.ico'))

GET('/blip', function(req, res)
	res.headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	res.headers['Cache-Control'] = 'max-age=0, must-revalidate'

	local now, ms = get_blip()
	res:add('[%s,%s]', now, ms)
end)

local function add_json(res, values)
	res:add('[')

	local n = #values
	if n > 0 then
		for i = 1, n-1 do
			local point = values[i]
			res:add('[%s,%s],', point[1], point[2])
		end
		local point = values[n]
		res:add('[%s,%s]', point[1], point[2])
	end

	res:add(']')
end

local db = assert(qpostgres.connect('user=powermeter dbname=powermeter'))
assert(db:prepare('get',  'SELECT stamp, ms FROM readings WHERE stamp >= $1 ORDER BY stamp LIMIT 2000'))
assert(db:prepare('last', 'SELECT stamp, ms FROM readings ORDER BY stamp DESC LIMIT 1'))

GET('/last', function(req, res)
	res.headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	res.headers['Cache-Control'] = 'max-age=0, must-revalidate'

	local point = assert(db:run('last'))[1]

	res:add('[%s,%s]', point[1], point[2])
end)

GETM('^/since/(%d+)$', function(req, res, since)
	res.headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	res.headers['Cache-Control'] = 'max-age=0, must-revalidate'
	add_json(res, assert(db:run('get', since)))
end)

GETM('^/last/(%d+)$', function(req, res, ms)
	res.headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	res.headers['Cache-Control'] = 'max-age=0, must-revalidate'

	local since = format('%0.f',
		gettimeofday() * 1000 - tonumber(ms))

	add_json(res, assert(db:run('get', since)))
end)

hathaway.debug = print
assert(Hathaway('*', arg[1] or 8080))

-- vim: syntax=lua ts=2 sw=2 noet:
