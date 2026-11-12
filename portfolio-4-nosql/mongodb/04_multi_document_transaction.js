// =====================================================================
// 04_multi_document_transaction.js - ACID transfer across 3 documents
// (2 account docs + 1 transaction doc) using a MongoDB session transaction
// with writeConcern "majority" and readConcern "snapshot".
// =====================================================================
db = db.getSiblingDB("nairaflow");

function transfer(from, to, amount, ref) {
  const session = db.getMongo().startSession();
  const accts = session.getDatabase("nairaflow").accounts;
  const txns  = session.getDatabase("nairaflow").transactions;
  const amt = NumberDecimal(amount.toFixed(2));
  try {
    session.withTransaction(() => {
      // conditional debit: only succeeds if ACTIVE and balance >= amount
      const r = accts.updateOne({ _id: from, status: "ACTIVE", balance: { $gte: amt } },
                                { $inc: { balance: NumberDecimal((-amount).toFixed(2)) } });
      if (r.modifiedCount !== 1) throw new Error("Insufficient funds or inactive account " + from);
      const c = accts.updateOne({ _id: to, status: "ACTIVE" }, { $inc: { balance: amt } });
      if (c.modifiedCount !== 1) throw new Error("Unknown or inactive beneficiary " + to);
      txns.insertOne({ _id: ref, type: "TRANSFER", status: "COMPLETED", amount: amt, channel: "MOBILE",
                       legs: [{ account: from, dir: "D", amount: amt }, { account: to, dir: "C", amount: amt }],
                       createdAt: new Date() });          // duplicate ref -> E11000 -> whole txn aborts
    }, { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
    print(`  COMMITTED  ${ref}: ${from} -> ${to}  N${amount}`);
  } catch (e) {
    print(`  ABORTED    ${ref}: ${e.message.split("\n")[0]}`);
  } finally { session.endSession(); }
}
const bal = (...ids) => db.accounts.find({ _id: { $in: ids } }, { balance: 1 }).sort({ _id: 1 })
                          .forEach(a => print(`    ${a._id}  ${a.balance}`));

const A = "4000000001", B = "4000000002", C = "4000000003";
print("Balances before:"); bal(A, B, C);
print("\n1) Valid transfer");                    transfer(A, B, 25000, "MDB-TX-001");
print("\n2) Insufficient funds -> rollback");     transfer(A, B, 99999999, "MDB-TX-002");
print("\n3) Unknown beneficiary -> debit of A is rolled back too"); transfer(A, "4999999999", 1000, "MDB-TX-003");
print("\n4) Duplicate reference (idempotency) -> rollback"); transfer(A, C, 500, "MDB-TX-001");
print("\nBalances after (A should be exactly 25,000 lower, B 25,000 higher):"); bal(A, B, C);
print("Transactions written:", db.transactions.countDocuments({ _id: /^MDB-TX/ }));
const tot = db.accounts.aggregate([{ $group: { _id: null, t: { $sum: "$balance" } } }]).toArray()[0].t;
print("Sum of all balances (must still be 0):", tot);
