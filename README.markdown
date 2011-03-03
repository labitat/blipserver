blipserver
==========


About
-----

This is the code running on [space.labitat.dk][space].

It reads data from the Arduino connected to the serial port,
which monitors the power meter in [Labitat][], and serves
the power graph and an API for retrieving past power meter data.

Each time the Arduino detects a new blink of the power meter it sends
the amount of milliseconds passed since last blink as a decimal string followed
by a newline (`"\n"`).

Upon receiving such a value from the Arduino the server attaches a timestamp
(unix timestamp in milliseconds) and stores this pair in a database.
It also returns the point to any clients doing long-polling to update the
live graph.

The server is written in [Lua][] using the [Lua Event Machine][lem],
along with the [stream][lem-streams] and [PostgreSQL][lem-postgres] libraries
for it.

[labitat]: https://labitat.dk
[space]: http://space.labitat.dk
[lua]: http://www.lua.org
[lem]: https://github.com/esmil/lem
[lem-streams]: https://github.com/esmil/lem-streams
[lem-postgres]: https://github.com/esmil/lem-postgres


API
---

The database stores pairs `(stamp, ms)` for each blink of the power meter.
Here `stamp` is a unix timestamp in milliseconds describing roughly when
the blink happened, and `ms` is the number of milliseconds which passed
since the last blink detected. We'll refer to such a pair as a "point".

The power meter blinks once for each Wh of power used (1000 times for each kWh).
Use the formula

    3600000 / ms

to calculate the (mean) power usage in Watts during the time interval
`[stamp - ms, stamp]`.

The points can be fetched by doing HTTP requests to various URIs.
So far [JSON][] is the only output format supported and points will be
returned in a JSON array `[stamp, ms]`.

Clients should not assume that `stamp1 + ms2 = stamp2` for every two
consecutive points `(stamp1, ms1)` and `(stamp2, ms2)`. There may be time drifts,
rounding errors or both. Also the blip server may have been down for some
period of time due to maintanence or other hacking and thus not been able
to log some blinks.

* __/blip__

  Use this URI to do long-polling. The server will not answer the request
  immediately, but instead wait until the next blink is detected and
  then return that point.

* __/last__

  Immediately returns the last point read.

* __/last/\<n\>__

  Returns a list points read during the last `<n>` milliseconds.

  If there are more than 2000 such points only the first 2000 will
  be returned.

* __/since/\<n\>__

  Returns a list of points since `<n>`, which must be a unix timestamp in
  milliseconds.

  If there are more than 2000 such points only the first 2000 will be
  returned, so use 1 plus the timestamp of the last point in the list to request
  the next 2000 points (again using this URI).

[JSON]: http://json.org

License
-------

blipserver is free software. It is distributed under the terms of the
[GNU General Public License][gpl].

[gpl]: http://www.fsf.org/licensing/licenses/gpl.html
