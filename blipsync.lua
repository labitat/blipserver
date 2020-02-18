#!/usr/bin/env lem
--
-- This file is part of blipserver.
-- Copyright 2019 Asbjørn Sloth Tønnesen
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

local httpclient   = require 'lem.http.client'
local json         = require 'json'

local assert = assert
local format = string.format

local whichdb = 'postgres'

local remote_url = 'http://spacepowermeter.labitat.dk'

local dbauth, qpostgres
if (whichdb == 'postgres') then
	qpostgres    = require 'lem.postgres.queued'
	dbauth = 'dbname=powermeter'
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
if (whichdb == 'postgres')  then
	runq = runq_postgres
end

local remote = {}
remote.__index = remote

function remote:open()
	self.c = httpclient.new()
	self.base_url = remote_url
	self.blip_url = remote_url .. '/blip'
end

function remote:range(from, to)
	local range_url = format('%s/range/%d/%d', self.base_url, from, to)
	print(range_url)
	local res, err = self.c:get(range_url)
	if not res then
		print(res, err)
		return
	end
	if res.status == 200 then
		local body = res:body()
		assert(body:sub(1,1) == '[')
		return assert(json.decode(body))
	end
end

function remote:get()
	while true do
		local res = self.c:get(self.blip_url)
		if res.status == 200 then
			local body = res:body()
			assert(body:sub(1,1) == '[')
			local data = assert(json.decode(body))
			return data[2], data[1]
		end
	end
end

-- Find all holes in the timeseries
-- first 2 columns (begin, end) is the same for all rows
-- the first row is returned to detect if begin is in a hole
local holes_sql = [[
select
	ss."w_begin",
	ss."w_end",
	ss.gap_begin,
	ss.gap_end,
	ss.ms,
	ss.elapsed,
	ss.gap,
	to_timestamp(ss."w_begin"/1000) "w_begin",
	to_timestamp(ss."w_end"/1000) "w_end",
	to_timestamp(ss."gap_begin"/1000) "gap_begin",
	to_timestamp(ss."gap_end"/1000) "gap_end"
from (select
    t."begin" "w_begin",
    t."end" "w_end",
    (lag(r.stamp) OVER w) "gap_begin",
    r.stamp "gap_end",
    r.ms,
		r.stamp - (lag(r.stamp) OVER w) "elapsed",
    r.stamp - ((lag(r.stamp) OVER w) + r.ms) gap
    from
      (select
        (extract(epoch from (now()-'1 week'::interval))*1000)::bigint "begin",
        (extract(epoch from now())*1000)::bigint "end"
      ) t
    left join
      readings r on r.stamp > t."begin" and r.stamp < t."end"
    window w AS (order by r.stamp)
) ss where abs(ss.gap) > 500 order by ss.gap;
]]

local db = {
	holes = holes_sql,
	put = 'INSERT INTO readings VALUES (?, ?)',
}

local function try_repair_hole(from, to)
	local gap = to - from
	print('hole', from, to, gap)
	local samples = remote:range(from, to)
	for i=1,#samples do
		local sample = samples[i]
		local stamp, ms = sample[1], sample[2]
		print('insert', stamp, ms)
		runq(db, 'put', stamp, ms)
	end
end

remote:open()
local rows = assert(runq(db, 'holes'))

if #rows > 0 then
	for i=1,#rows do
		local row = rows[i]
		print('hole', row[10], row[11], row[7])
		try_repair_hole(row[3], row[4])
	end
end

-- vim: syntax=lua ts=2 sw=2 noet:
