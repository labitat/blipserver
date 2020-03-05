#!/usr/bin/env lem
--
-- This file is part of labibus.
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
local serialdev = '/dev/serial/labibus'
--local serialdev = '/dev/tty'

local dbauth, postgres, qpostgres, mariadb, qmariadb
if (whichdb == 'mariadb') then
	mariadb     = require 'lem.mariadb'
	qmariadb    = require 'lem.mariadb.queued'
	dbauth = {host="192.168.1.7",user="blipserver",passwd="pass",db="blipserver"}
end
if (whichdb == 'postgres') then
	postgres     = require 'lem.postgres'
	qpostgres    = require 'lem.postgres.queued'
	dbauth = 'user=powermeter dbname=powermeter'
end

local blip = queue.new()

function runq_mariadb(db, query, ...)
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

function runq_postgres(db, name, ...)
	if (db.conn) then
		local r, m = ((db.conn):run(name, ...))
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


-- Labibus.

local labibus = { }

local function unquote(s)
	local repl = function(m) return string.char(tonumber(m, 16)) end
	local u = s:gsub('\\([0-9a-fA-F][0-9a-fA-F])', repl)
	return u
end

utils.spawn(function()
	local serial = assert(io.open(serialdev, 'r+'))
	local db = {
		labibus_put = 'INSERT INTO device_log VALUES (?, ?, ?)',
		-- Placeholders: device,stamp,descr,unit,
		--               poll_interval,device,descr,unit,poll_interval
		dev_active = 'INSERT INTO device_history SELECT ?, ?, TRUE, ?, ?, ?' ..
			' WHERE NOT EXISTS (SELECT 1 FROM device_status ' ..
			'   WHERE id = ? AND active AND description = ?' ..
			'     AND unit = ? AND poll_interval = ?)',
		-- Placeholders: device, stamp
		dev_inactive = 'INSERT INTO device_history' ..
			' SELECT ?, ?, FALSE, NULL, NULL, NULL' ..
			' WHERE EXISTS (SELECT 1 FROM device_status' ..
			'   WHERE id = ? AND active)'
	}

	local now = utils.now

	-- Sending stuff to the master forces a full status report.
	assert(serial:write('hitme!\n'))

	while true do
		local line = assert(serial:read('*l'))
		local stamp = format('%0.f', now() * 1000)

		local dev = line:match('^INACTIVE ([0-9]+)$')
		if dev then
			local q = labibus[dev]
			if q then
				labibus[dev] = nil
				q:signal(nil, nil)
				q:reset()
			end
			assert(runq(db, 'dev_inactive', dev, stamp, dev))
		else
		local dev, interval, desc_q, unit_q = line:match('^ACTIVE ([0-9]+)|([0-9]+)|([^|]*)|([^|]*)$')
		if dev then
			local desc = unquote(desc_q)
			local unit = unquote(unit_q)
			if not labibus[dev] then
				labibus[dev] = queue.new()
			end
			assert(runq(db, 'dev_active', dev, stamp, desc, unit,
				    interval, dev, desc, unit, interval))
		else
		local dev, val = line:match('^POLL ([0-9]+) (.*)$')
		if dev then
			local q = labibus[dev]
			if q then
				q:signal(stamp, val)
			end
			assert(runq(db, 'labibus_put', dev, stamp, val))
		end end end
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

local labibus_html = sendfile('text/html; charset=UTF-8', 'labibus.html')

--hathaway.debug = print
hathaway.import()

GET('/',               labibus_html)
GET('/index.html',     labibus_html)
GET('/labibus',        labibus_html)
GET('/labibus.html',   labibus_html)
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

local function add_data(res, values)
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

local function add_device_json(res, values)
	res:add('[')

	local n = #values
	if n > 0 then
		for i = 1, n-1 do
			local r = values[i]
			if r[2] == "t" then
				res:add('[%s,1,%s,%s,%s],', r[1], string.format("%q",r[3]), string.format("%q",r[4]), r[5])
			else
				res:add('[%s,0,%s,%s,%s],', r[1], string.format("%q",r[3]), string.format("%q",r[4]), r[5])
			end
		end
		local r = values[n]
		if r[2] == "t" then
			res:add('[%s,1,%s,%s,%s]', r[1], string.format("%q",r[3]), string.format("%q",r[4]), r[5])
		else
			res:add('[%s,0,%s,%s,%s],', r[1], string.format("%q",r[3]), string.format("%q",r[4]), r[5])
		end
	end

	res:add(']')
end

local function add_json6(res, values)
  res:add('[')

  local n = #values
  if n > 0 then
    for i = 1, n-1 do
      local point = values[i]
      res:add('[%s,%s,%s,%s,%s,%s],', point[1], point[2], point[3], point[4], point[5], point[6])
    end
    local point = values[n]
    res:add('[%s,%s,%s,%s,%s,%s]', point[1], point[2], point[3], point[4], point[5], point[6])
  end

  res:add(']')
end

local db = {
	labibus_status = 'SELECT id, active, description, unit, poll_interval ' ..
		'FROM device_last_active_status ORDER BY id',
	labibus_datahdr = 'SELECT id, active, description, unit, poll_interval ' ..
		'FROM device_last_active_status WHERE id = ?',
	labibus_data = 'select stamp, value from device_log where id = ? ' ..
		'order by stamp desc limit ?',
	labibus_last = 'SELECT stamp, value FROM device_log ' ..
		'WHERE id = ? AND stamp >= ? ORDER BY stamp LIMIT 20000',
	labibus_range = 'SELECT stamp, value FROM device_log ' ..
	   'WHERE id = ? AND stamp >= ? AND stamp <= ? ' ..
	   'ORDER BY stamp LIMIT 100000',
	labibus_minutely =
	   'SELECT stamp, events, sum_value, sum_sqvalue, min_value, max_value ' ..
	   'FROM device_log_minutely ' ..
	   'WHERE id = ? AND stamp >= ? AND stamp <= ? ' ..
	   'ORDER BY stamp LIMIT 100000',
	labibus_hourly =
	   'SELECT stamp, events, sum_value, sum_sqvalue, min_value, max_value ' ..
	   'FROM device_log_hourly ' ..
	   'WHERE id = ? AND stamp >= ? AND stamp <= ? ' ..
	   'ORDER BY stamp LIMIT 100000'
}


-- Labibus

OPTIONS('/labibus_status', apioptions)
GET('/labibus_status', function(req, res)
	apiheaders(res.headers)

	add_device_json(res, assert(runq(db, 'labibus_status')))
end)

OPTIONSM('^/labibus_status/(%d+)$', apioptions)
GETM('^/labibus_status/(%d+)$', function(req, res, dev)
	apiheaders(res.headers)

	add_device_json(res, assert(runq(db, 'labibus_datahdr', dev)))
end)

OPTIONSM('^/labibus_data/(%d+)$', apioptions)
GETM('^/labibus_data/(%d+)$', function(req, res, dev)
	apiheaders(res.headers)

	add_data(res, assert(runq(db, 'labibus_data', dev, 20000)))
end)

OPTIONSM('^/labibus_data/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_data/(%d+)/(%d+)$', function(req, res, dev, howmany)
  apiheaders(res.headers)

  add_data(res, assert(runq(db, 'labibus_data', dev, howmany)))
end)

OPTIONSM('^/labibus_blip/(%d+)$', apioptions)
GETM('^/labibus_blip/(%d+)$', function(req, res, dev)
	apiheaders(res.headers)
	local q = labibus[dev]
	if q then
		local stamp, val = q:get()
		if stamp then
			res:add('[%s,%s]', stamp, val)
		end
	end
end)

OPTIONSM('^/labibus_last/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_last/(%d+)/(%d+)$', function(req, res, dev, ms)
  if #ms > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)

  local since = format('%0.f',
    utils.now() * 1000 - tonumber(ms))

  add_json(res, assert(runq(db, 'labibus_last', dev, since)))
end)

OPTIONSM('^/labibus_since/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_since/(%d+)/(%d+)$', function(req, res, dev, since)
  if #since > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json(res, assert(runq(db, 'labibus_last', dev, since)))
end)

OPTIONSM('^/labibus_range/(%d+)/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_range/(%d+)/(%d+)/(%d+)$', function(req, res, dev, from, to)
  if #from > 15 or #to > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json(res, assert(runq(db, 'labibus_range', dev, from, to)))
end)

OPTIONSM('^/labibus_minutely/(%d+)/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_minutely/(%d+)/(%d+)/(%d+)$', function(req, res, dev, from, to)
  if #from > 15 or #to > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json6(res, assert(runq(db, 'labibus_minutely', dev, from, to)))
end)

OPTIONSM('^/labibus_hourly/(%d+)/(%d+)/(%d+)$', apioptions)
GETM('^/labibus_hourly/(%d+)/(%d+)/(%d+)$', function(req, res, dev, from, to)
  if #from > 15 or #to > 15 then
    bad_request(req, res)
    return
  end
  apiheaders(res.headers)
  add_json6(res, assert(runq(db, 'labibus_hourly', dev, from, to)))
end)

assert(Hathaway('*', arg[1] or 8081))

-- vim: syntax=lua ts=2 sw=2 noet:
