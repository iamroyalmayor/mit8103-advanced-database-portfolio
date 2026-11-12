// =====================================================================
// 02_load_data.js - synthetic data: 5,000 customers, 8,000 accounts,
// 150,000 transactions (with embedded legs), then monthly statement buckets
// built server-side with an aggregation pipeline ($merge).
// =====================================================================
db = db.getSiblingDB("nairaflow");
const D = (x) => NumberDecimal(x.toFixed(2));
let seed = 8103;                                   // deterministic PRNG (mulberry32)
function rnd() { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }
const pick = (a) => a[Math.floor(rnd() * a.length)];
const FIRST = ["Adaeze","Tunde","Chinedu","Fatima","Emeka","Halima","Seun","Ibrahim","Ngozi","Osagie","Aisha","Kelechi"];
const LAST  = ["Okafor","Adeyemi","Eze","Bello","Nwosu","Yusuf","Balogun","Musa","Obi","Igbinedion","Lawal","Okeke"];
const STATES = ["Lagos","Lagos","Lagos","Oyo","Ogun","FCT Abuja","Kano","Kaduna","Rivers","Edo","Enugu","Anambra","Borno","Plateau"];
const CHANNELS = ["MOBILE","MOBILE","MOBILE","USSD","WEB","POS","ATM"];
const NOW = new Date();
const daysAgo = (d) => new Date(NOW.getTime() - d * 86400000);

// ---- customers ----
let customers = [];
for (let i = 1; i <= 5000; i++) {
  const c = { _id: "CUS-" + String(i).padStart(6, "0"), bvn: String(22300000000 + i),
    name: { first: pick(FIRST), last: pick(LAST) },
    phone: "+234" + String(8100000000 + i), email: `cust${i}@mail.example.ng`,
    kyc: { tier: NumberInt(1 + Math.floor(rnd() * 3)), verified: rnd() < 0.9,
           documents: rnd() < 0.5 ? [{ type: "NIN", number: String(10000000000 + i) }] : [] },
    address: { state: pick(STATES), city: "—" },
    devices: [{ id: "dev-" + i, os: pick(["Android","iOS"]), lastSeen: daysAgo(rnd() * 30) }],
    beneficiaries: [], createdAt: daysAgo(400 + rnd() * 300) };
  // polymorphism: business customers carry extra attributes, retail ones do not
  if (rnd() < 0.15) c.business = { rcNumber: "RC" + (100000 + i), sector: pick(["Retail","Agro","Logistics","Tech"]) };
  customers.push(c);
}
db.customers.insertMany(customers);

// ---- accounts (+ 1 GL) ----
let accounts = [{ _id: "9000000001", customerId: "BANK", holderName: "NairaFlow Cash GL", type: "GL",
                  currency: "NGN", balance: D(0), status: "ACTIVE" }];
for (let i = 1; i <= 8000; i++) {
  const c = customers[(i - 1) % 5000];
  accounts.push({ _id: String(4000000000 + i), customerId: c._id, holderName: c.name.first + " " + c.name.last,
                  type: rnd() < 0.75 ? "SAVINGS" : "CURRENT", currency: "NGN", balance: D(0), status: "ACTIVE",
                  openedAt: daysAgo(380 + rnd() * 100) });
}
db.accounts.insertMany(accounts);
const acctIds = accounts.slice(1).map(a => a._id);

// ---- transactions with embedded legs ----
let bal = {}; acctIds.forEach(a => bal[a] = 0); bal["9000000001"] = 0;
let batch = [], n = 0;
function post(doc) { batch.push(doc); if (batch.length === 5000) { db.transactions.insertMany(batch); batch = []; } }
acctIds.forEach((a, i) => {          // opening deposits
  bal[a] += 500000; bal["9000000001"] -= 500000;
  post({ _id: "DEP-" + a, type: "DEPOSIT", status: "COMPLETED", amount: D(500000), channel: "BRANCH",
         legs: [{ account: "9000000001", dir: "D", amount: D(500000) }, { account: a, dir: "C", amount: D(500000) }],
         createdAt: daysAgo(370) });
});
for (let i = 1; i <= 150000; i++) {
  const from = pick(acctIds); let to = pick(acctIds); if (to === from) continue;
  const amt = Math.round((100 + rnd() * 19900) * 100) / 100;
  const failed = rnd() < 0.05;
  const doc = { _id: "TRF-" + String(i).padStart(7, "0"), type: "TRANSFER", status: failed ? "FAILED" : "COMPLETED",
    amount: D(amt), channel: pick(CHANNELS), legs: [], createdAt: daysAgo(rnd() * 365),
    meta: { device: "dev-" + from.slice(-4) } };
  if (doc.channel === "POS") doc.meta.terminal = "POS-" + Math.floor(rnd() * 900 + 100);   // flexible schema
  if (failed) { doc.meta.failureReason = pick(["NIBSS timeout", "Insufficient funds", "Invalid PIN"]); }
  else { doc.legs = [{ account: from, dir: "D", amount: D(amt) }, { account: to, dir: "C", amount: D(amt) }];
         bal[from] -= amt; bal[to] += amt; }
  post(doc); n++;
}
if (batch.length) db.transactions.insertMany(batch);

// ---- materialise balances (bulkWrite) ----
db.accounts.bulkWrite(Object.entries(bal).map(([k, v]) =>
  ({ updateOne: { filter: { _id: k }, update: { $set: { balance: D(v) } } } })));

// ---- statements: bucket pattern built entirely on the server ----
db.transactions.aggregate([
  { $match: { status: "COMPLETED" } },
  { $unwind: "$legs" },
  { $sort: { createdAt: 1 } },
  { $group: { _id: { account: "$legs.account", month: { $dateToString: { format: "%Y-%m", date: "$createdAt" } } },
              entries: { $push: { txn: "$_id", at: "$createdAt", dir: "$legs.dir", amount: "$legs.amount", channel: "$channel" } },
              credits: { $sum: { $cond: [{ $eq: ["$legs.dir", "C"] }, "$legs.amount", NumberDecimal("0")] } },
              debits:  { $sum: { $cond: [{ $eq: ["$legs.dir", "D"] }, "$legs.amount", NumberDecimal("0")] } },
              count:   { $sum: 1 } } },
  { $project: { _id: { $concat: ["$_id.account", ":", "$_id.month"] }, account: "$_id.account",
                month: "$_id.month", entries: 1, credits: 1, debits: 1, count: 1 } },
  { $merge: { into: "statements", whenMatched: "replace" } }
], { allowDiskUse: true });

print("customers   :", db.customers.countDocuments());
print("accounts    :", db.accounts.countDocuments());
print("transactions:", db.transactions.countDocuments());
print("statements  :", db.statements.countDocuments(), "(account-month buckets)");
const tot = db.accounts.aggregate([{ $group: { _id: null, total: { $sum: "$balance" } } }]).toArray()[0].total;
print("sum of all balances (must be 0):", tot);
print("\nSample customer document (embedded KYC, devices, beneficiaries):");
printjson(db.customers.findOne({ business: { $exists: true } }));
print("\nSample transaction document (embedded legs + flexible meta):");
printjson(db.transactions.findOne({ channel: "POS", status: "COMPLETED" }));
print("\nSample statement bucket (first 3 entries shown):");
printjson(db.statements.findOne({}, { account: 1, month: 1, count: 1, credits: 1, debits: 1, entries: { $slice: 3 } }));
