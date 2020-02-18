#!/usr/bin/env lem
--
-- This file is part of blipserver.
-- Copyright 2011,2016 Emil Renner Berthing
-- Copyright 2016 Kristian Nielsen <knielsen@knielsen-hq.org>
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
local queue        = require 'lem.queue'
local io           = require 'lem.io'
local httpresp     = require 'lem.http.response'
local hathaway     = require 'lem.hathaway'

local assert = assert
local format = string.format
local tonumber = tonumber
local bad_request = httpresp.bad_request

local whichdb = 'postgres'
--local whichdb = 'mariadb'
local serialdev = '/dev/serial/blipduino'
--local serialdev = '/dev/tty'

local dbauth, qpostgres, qmariadb
if (whichdb == 'mariadb') then
	qmariadb    = require 'lem.mariadb.queued'
	dbauth = {host="192.168.1.7",user="blipserver",passwd="pass",db="blipserver"}
end
if (whichdb == 'postgres') then
	qpostgres    = require 'lem.postgres.queued'
	dbauth = 'user=powermeter dbname=powermeter'
end

local blip = queue.new()

local function runq_mariadb(db, query, ...)
	if (db.conn) then
		local r, m, e = (db[query][2]):run(...)
		if (r or (e ~= 2006 and e ~= 2013)) then
			return r, m, e
		end
	end
	-- Try to reconnect
	db.conn = assert(qmariadb.connect(dbauth))
	for q_name, q in pairs(db) do
		if (q_name ~= "conn") then
			if (type(q) == "string") then
				q = {q}
				db[q_name] = q
			end
			q[2] = assert((db.conn):prepare(q[1]))
		end
	end
	return assert(db[query][2]):run(...)
end

local function runq_postgres(db, name, ...)
	if (db.conn) then
		local r, m = (db.conn):run(name, ...)
		-- ToDo: Check for connection lost failure, and if so, fall
		-- through to reconnect and retry the query.
		return r, m
	end
	-- Try to connect
	db.conn = assert(qpostgres.connect(dbauth))
	for q_name, q in pairs(db) do
		if (q_name ~= "conn") then
			-- Convert to postgres-style placeholders $N
			local idx = 0
			local f = function ()
				idx = idx+1
				return "$" .. idx
			end
			local pq = string.gsub(q, "%?", f)
			assert((db.conn):prepare(q_name, pq))
		end
	end
	return (db.conn):run(name, ...)
end

local runq
if (whichdb == 'mariadb') then
	runq = runq_mariadb
end
if (whichdb == 'postgres')  then
	runq = runq_postgres
end

utils.spawn(function()
	local serial = assert(io.open(serialdev, 'r'))
	local db = {
		put = 'INSERT INTO readings VALUES (?, ?)'
	}
	local now = utils.now

	-- discard first two readings
	assert(serial:read('*l'))
	assert(serial:read('*l'))

	while true do
		local ms = assert(serial:read('*l'))
		local stamp = format('%0.f', now() * 1000)

--		print(stamp, ms, blip.n)
		blip:signal(stamp, ms)
		assert(runq(db, 'put', stamp, ms))
--		print('waiting for next event')
	end
end)


local function sendfile(content, path)
	local file = assert(io.open(path))
	local size = assert(file:size())
	return function(req, res)
		res.headers['Content-Type'] = content
		res.headers['Content-Length'] = size
		res.file = file
	end
end

local index_html = sendfile('text/html; charset=UTF-8', 'index.html')
local oldindex_html = sendfile('text/html; charset=UTF-8', 'oldindex.html')
local labibus_html = sendfile('text/html; charset=UTF-8', 'power_labibus.html')
local lastweek_html = sendfile('text/html; charset=UTF-8', 'lastweek.html')
local lastmonth_html = sendfile('text/html; charset=UTF-8', 'lastmonth.html')
local lastyear_html = sendfile('text/html; charset=UTF-8', 'lastyear.html')

--hathaway.debug = print
hathaway.import()

GET('/',               index_html)
GET('/index.html',     index_html)
GET('/oldblips.html',  index_html)
GET('/oldindex.html',  oldindex_html)
GET('/labibus',        labibus_html)
GET('/labibus.html',   labibus_html)
GET('/lastweek.html',  lastweek_html)
GET('/lastmonth.html', lastmonth_html)
GET('/lastyear.html',  lastyear_html)
GET('/jquery.js',      sendfile('text/javascript; charset=UTF-8', 'jquery.js'))
GET('/jquery.flot.js', sendfile('text/javascript; charset=UTF-8', 'jquery.flot.js'))
GET('/excanvas.js',    sendfile('text/javascript; charset=UTF-8', 'excanvas.js'))
GET('/ribbon.png',     sendfile('image/png',                      'ribbon.png'))
GET('/favicon.ico',    sendfile('image/x-icon',                   'favicon.ico'))

local function apiheaders(headers)
	headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	headers['Cache-Control'] = 'max-age=0, must-revalidate'
	headers['Access-Control-Allow-Origin'] = '*'
	headers['Access-Control-Allow-Methods'] = 'GET'
	headers['Access-Control-Allow-Headers'] = 'origin, x-requested-with, accept'
	headers['Access-Control-Max-Age'] = '60'
end

local function apioptions(req, res)
	apiheaders(res.headers)
	res.status = 200
end

OPTIONS('/blip', apioptions)
GET('/blip', function(req, res)
	apiheaders(res.headers)

	local stamp, ms = blip:get()
	res:add('[%s,%s]', stamp, ms)
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

local function add_json5(res, values)
  res:add('[')

  local n = #values
  if n > 0 then
    for i = 1, n-1 do
      local point = values[i]
      res:add('[%s,%s,%s,%s,%s],', point[1], point[2], point[3], point[4], point[5])
    end
    local point = values[n]
    res:add('[%s,%s,%s,%s,%s]', point[1], point[2], point[3], point[4], point[5])
  end

  res:add(']')
end


local db = {
	get = 'SELECT stamp, ms FROM readings WHERE stamp >= ? ORDER BY stamp LIMIT 2000',
	range = 'SELECT stamp, ms FROM readings WHERE stamp >= ? AND stamp <= ? ' ..
		'ORDER BY stamp LIMIT 100000',
	last = 'SELECT stamp, ms FROM readings ORDER BY stamp DESC LIMIT 1',
	aggregate = 'SELECT ?*((stamp - ?) DIV ?) hour_stamp, COUNT(ms) ' ..
		'FROM readings ' ..
		'WHERE stamp >=? AND stamp < ?+?*? ' ..
		'GROUP BY hour_stamp ORDER BY hour_stamp',
	hourly = 'SELECT stamp, events, wh, min_ms, max_ms FROM usage_hourly ' ..
		'WHERE stamp >= ? AND stamp <= ? ORDER BY stamp',
	minutely = 'SELECT stamp, events, wh, min_ms, max_ms FROM usage_minutely ' ..
		'WHERE stamp >= ? AND stamp <= ? ORDER BY stamp LIMIT 100000'
}
if (whichdb == 'postgres') then
	db.aggregate = 'SELECT ?::DOUBLE PRECISION*DIV(stamp - ?, ?) hour_stamp,' ..
		'COUNT(ms) FROM readings WHERE stamp >=? AND ' ..
		'stamp < ?+?::DOUBLE PRECISION*? ' ..
		'GROUP BY hour_stamp ORDER BY hour_stamp'
end

OPTIONS('/last', apioptions)
GET('/last', function(req, res)
	apiheaders(res.headers)

	local point = assert(runq(db, 'last'))[1]

	res:add('[%s,%s]', point[1], point[2])
end)

OPTIONSM('^/since/(%d+)$', apioptions)
GETM('^/since/(%d+)$', function(req, res, since)
	if #since > 15 then
		bad_request(req, res)
		return
	end
	apiheaders(res.headers)
	add_json(res, assert(runq(db, 'get', since)))
end)

OPTIONSM('^/range/(%d+)/(%d+)$', apioptions)
GETM('^/range/(%d+)/(%d+)$', function(req, res, since, upto)
	if #since > 15 or #upto > 15 then
		bad_request(req, res)
		return
	end
	apiheaders(res.headers)
	add_json(res, assert(runq(db, 'range', since, upto)))
end)

OPTIONSM('^/aggregate/(%d+)/(%d+)/(%d+)$', apioptions)
GETM('^/aggregate/(%d+)/(%d+)/(%d+)$', function(req, res, since, interval, count)
	if #since > 15 or #interval > 15 or #count > 15 or tonumber(count) > 1000 then
		bad_request(req, res)
		return
	end
	apiheaders(res.headers)
	add_json(res, assert(runq(db, 'aggregate', interval, since,
				  interval, since, since, interval, count)))
end)

OPTIONSM('^/hourly/(%d+)/(%d+)$', apioptions)
GETM('^/hourly/(%d+)/(%d+)$', function(req, res, since, last)
  if #since > 15 or #last > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json5(res, assert(runq(db, 'hourly', since, last)))
end)

OPTIONSM('^/minutely/(%d+)/(%d+)$', apioptions)
GETM('^/minutely/(%d+)/(%d+)$', function(req, res, since, last)
  if #since > 15 or #last > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json5(res, assert(runq(db, 'minutely', since, last)))
end)

OPTIONSM('^/last/(%d+)$', apioptions)
GETM('^/last/(%d+)$', function(req, res, ms)
	if #ms > 15 then
		bad_request(req, res)
		return
	end
	apiheaders(res.headers)

	local since = format('%0.f',
		utils.now() * 1000 - tonumber(ms))

	add_json(res, assert(runq(db, 'get', since)))
end)


assert(Hathaway('*', arg[1] or 8080))

-- vim: syntax=lua ts=2 sw=2 noet:
