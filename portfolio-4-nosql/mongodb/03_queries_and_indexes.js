// =====================================================================
// 03_queries_and_indexes.js - typical NairaFlow reads, each with
// explain("executionStats") BEFORE and AFTER a purpose-built index.
// =====================================================================
db = db.getSiblingDB("nairaflow");
db.transactions.dropIndexes(); db.customers.dropIndexes();

function stats(label, cursorOrAgg) {
  const e = cursorOrAgg;
  const s = e.executionStats || (e.stages && e.stages[0].$cursor.executionStats);
  const plan = JSON.stringify(e.queryPlanner ? e.queryPlanner.winningPlan
                                              : e.stages[0].$cursor.queryPlanner.winningPlan);
  const stage = plan.includes("COLLSCAN") ? "COLLSCAN" : (plan.match(/IXSCAN|IDHACK|EXPRESS_IXSCAN/) || ["?"])[0];
  print(`  ${label.padEnd(8)} stage=${stage.padEnd(8)} docsExamined=${String(s.totalDocsExamined).padEnd(7)}` +
        ` keysExamined=${String(s.totalKeysExamined).padEnd(7)} returned=${String(s.nReturned).padEnd(5)} ms=${s.executionTimeMillis}`);
}
const ACC = "4000001234";
const since = new Date(Date.now() - 90 * 86400000);

// ---------- M1: account history (multikey index on embedded array field) ----------
print("\n### M1 Last 90 days of activity for account " + ACC + " (query on embedded legs.account)");
const m1 = () => db.transactions.find({ "legs.account": ACC, createdAt: { $gte: since } })
                                .sort({ createdAt: -1 });
stats("before", m1().explain("executionStats"));
db.transactions.createIndex({ "legs.account": 1, createdAt: -1 }, { name: "ix_legs_account_time" });
stats("after", m1().explain("executionStats"));
m1().limit(3).forEach(t => print(`   ${t.createdAt.toISOString().slice(0,16)} ${t._id} ${t.channel} ` +
      t.legs.find(l => l.account === ACC).dir + " " + t.amount));

// ---------- M2: same need served by ONE statement bucket document ----------
print("\n### M2 Same need via bucket pattern: one document per account-month");
const month = new Date().toISOString().slice(0, 7);
const b = db.statements.findOne({ _id: ACC + ":" + month });
print(`  statement ${ACC}:${month} -> ${b ? b.count : 0} entries in a single document read (lookup by _id)`);
stats("bucket", db.statements.find({ _id: ACC + ":" + month }).explain("executionStats"));

// ---------- M3: customer login by phone (unique index) ----------
print("\n### M3 Login lookup by phone number");
const m3 = () => db.customers.find({ phone: "+2348100004521" }, { name: 1, kyc: 1 });
stats("before", m3().explain("executionStats"));
db.customers.createIndex({ phone: 1 }, { unique: true, name: "ux_phone" });
db.customers.createIndex({ bvn: 1 },   { unique: true, name: "ux_bvn" });
stats("after", m3().explain("executionStats"));
printjson(m3().toArray()[0]);

// ---------- M4: failed transactions dashboard (partial index) ----------
print("\n### M4 Failed transactions by channel and reason, last 30 days (aggregation)");
const m4 = [ { $match: { status: "FAILED", createdAt: { $gte: new Date(Date.now() - 30 * 86400000) } } },
             { $group: { _id: { channel: "$channel", reason: "$meta.failureReason" }, n: { $sum: 1 } } },
             { $sort: { n: -1 } }, { $limit: 5 } ];
stats("before", db.transactions.explain("executionStats").aggregate(m4));
db.transactions.createIndex({ createdAt: -1 },
  { name: "ix_failed_recent", partialFilterExpression: { status: "FAILED" } });
stats("after", db.transactions.explain("executionStats").aggregate(m4));
db.transactions.aggregate(m4).forEach(r => print(`   ${r._id.channel.padEnd(7)} ${String(r._id.reason).padEnd(20)} ${r.n}`));

// ---------- M5: analytics - value by customer state ($lookup join) ----------
print("\n### M5 Total balances by customer state ($lookup = application-side join cost)");
db.accounts.aggregate([
  { $match: { type: { $ne: "GL" } } },
  { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "c",
               pipeline: [{ $project: { "address.state": 1 } }] } },
  { $group: { _id: { $first: "$c.address.state" }, accounts: { $sum: 1 }, total: { $sum: "$balance" } } },
  { $sort: { total: -1 } }, { $limit: 5 }
]).forEach(r => print(`   ${r._id.padEnd(10)} accounts=${String(r.accounts).padEnd(5)} total=${r.total}`));

// ---------- M6: schema flexibility - query a field only some documents have ----------
print("\n### M6 Polymorphic documents: business customers by sector (field exists on ~15% of docs)");
db.customers.aggregate([{ $match: { business: { $exists: true } } },
                        { $group: { _id: "$business.sector", n: { $sum: 1 } } }, { $sort: { _id: 1 } }])
  .forEach(r => print(`   ${r._id.padEnd(10)} ${r.n}`));

// ---------- M7: validation rejects a bad document ----------
print("\n### M7 $jsonSchema validation rejects malformed data");
try { db.customers.insertOne({ _id: "CUS-BAD", bvn: "123", name: { first: "X", last: "Y" },
        phone: "08030000000", email: "x@y", kyc: { tier: NumberInt(9), verified: true },
        address: { state: "Lagos" }, createdAt: new Date() }); }
catch (e) { print("   rejected:", e.errInfo ? e.errInfo.details.schemaRulesNotSatisfied.map(r =>
             (r.propertiesNotSatisfied || []).map(p => p.propertyName).join(",")).join(" ") : e.message); }

print("\nIndexes on transactions:"); db.transactions.getIndexes().forEach(i => print("  ", i.name, JSON.stringify(i.key)));
