#!/usr/bin/env bash
# NairaFlow | Portfolio 5 - MongoDB 3-member replica set: replication, write/read concerns, automatic failover
export MSYS_NO_PATHCONV=1
URI="mongodb://p5-mongo1:27017,p5-mongo2:27017,p5-mongo3:27017/nairaflow?replicaSet=rs5"
M()  { docker exec "$1" mongosh --quiet --eval "$2" 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g'; }
RS() { docker exec "$1" mongosh --quiet "$URI" --eval "$2" 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g'; }
hdr(){ echo; echo "=================================================================="; echo "$1"; echo "=================================================================="; }
members='rs.status().members.forEach(m => print("  " + m.name.padEnd(18) + m.stateStr.padEnd(11) + "optime=" + m.optimeDate.toISOString()))'

hdr "M1 Initiate replica set rs5 (priority 2 on mongo1 makes it the preferred primary)"
M p5-mongo1 'rs.initiate({_id:"rs5", members:[
   {_id:0, host:"p5-mongo1:27017", priority:2},
   {_id:1, host:"p5-mongo2:27017", priority:1},
   {_id:2, host:"p5-mongo3:27017", priority:1}]}).ok'
until [ "$(M p5-mongo1 'db.hello().isWritablePrimary')" = "true" ]; do sleep 1; done
sleep 3
M p5-mongo1 "$members"

hdr "M2 Write with writeConcern majority (acknowledged by 2 of 3 members), then read from a SECONDARY"
RS p5-mongo1 '
  db.transactions.insertOne({_id:"P5-TX-1", type:"TRANSFER", amount:NumberDecimal("12000.00"),
     legs:[{account:"0123456781",dir:"D"},{account:"0123456783",dir:"C"}], createdAt:new Date()},
     {writeConcern:{w:"majority", wtimeout:5000}});
  print("  inserted with w:majority");
  const d2 = db.transactions.find({_id:"P5-TX-1"}).readPref("secondary").readConcern("majority").toArray()[0];
  print("  read from secondary ->", d2 ? d2._id + " amount " + d2.amount : "not yet replicated");'

hdr "M3 Unsatisfiable write concern: error is returned, but the write itself is NOT rolled back"
RS p5-mongo1 '
  try { db.transactions.insertOne({_id:"P5-TX-W5", amount:NumberDecimal("1")}, {writeConcern:{w:5, wtimeout:2000}}); }
  catch (e) { print("  w:5 on a 3-member set ->", e.codeName || e.message); }'

hdr "M4 Automatic failover: kill the PRIMARY and time the election"
PRIMARY=$(M p5-mongo2 'rs.status().members.find(m => m.stateStr=="PRIMARY").name.split(":")[0]')
echo "  current primary: $PRIMARY"
T0=$(date +%s%3N)
docker kill "$PRIMARY" >/dev/null && echo "  $PRIMARY killed at $(date +%T.%3N)"
SURVIVOR=p5-mongo2; [ "$PRIMARY" = "p5-mongo2" ] && SURVIVOR=p5-mongo3
until [ "$(M $SURVIVOR 'rs.status().members.some(m => m.stateStr=="PRIMARY")')" = "true" ]; do sleep 0.5; done
T1=$(date +%s%3N)
echo "  new primary elected after ~$(( (T1 - T0) / 1000 )).$(( (T1 - T0) % 1000 / 100 )) s"
M $SURVIVOR "$members"

hdr "M5 Writes continue on the new primary (driver re-discovers topology, retryable writes)"
RS $SURVIVOR '
  const r = db.transactions.insertOne({_id:"P5-TX-2", type:"TRANSFER", amount:NumberDecimal("3000.00"), createdAt:new Date()},
                                      {writeConcern:{w:"majority", wtimeout:5000}});
  print("  insert acknowledged:", r.acknowledged, "| primary is now", db.hello().primary);
  print("  documents:", db.transactions.countDocuments({_id:/^P5-TX/}));'

hdr "M6 Old primary restarts, rejoins as SECONDARY, catches up, then regains PRIMARY (higher priority)"
docker start "$PRIMARY" >/dev/null
sleep 15
M $SURVIVOR "$members"
RS $SURVIVOR 'print("  P5-TX-2 present on rejoined node:", db.getSiblingDB("nairaflow").transactions.find({_id:"P5-TX-2"}).readPref("nearest").count() == 1)'
