// =====================================================================
// NairaFlow | Portfolio 4: NoSQL and Advanced Data Models
// 01_collections_and_validation.js
// Document model for the same NairaFlow bank, with $jsonSchema validation.
// Run: mongosh "mongodb://localhost:27017/nairaflow?replicaSet=rs0" 01_collections_and_validation.js
// =====================================================================
db = db.getSiblingDB("nairaflow");
db.dropDatabase();

// ---------- customers: KYC profile, devices and beneficiaries EMBEDDED ----------
// Read together on every login, small and bounded -> embedding avoids joins.
db.createCollection("customers", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "bvn", "name", "phone", "email", "kyc", "address", "createdAt"],
    properties: {
      _id:   { bsonType: "string", description: "customer id e.g. CUS-000001" },
      bvn:   { bsonType: "string", pattern: "^[0-9]{11}$" },
      name:  { bsonType: "object", required: ["first", "last"],
               properties: { first: { bsonType: "string" }, last: { bsonType: "string" } } },
      phone: { bsonType: "string", pattern: "^\\+234[0-9]{10}$" },
      email: { bsonType: "string", pattern: "^.+@.+$" },
      kyc:   { bsonType: "object", required: ["tier", "verified"],
               properties: { tier: { bsonType: "int", minimum: 1, maximum: 3 },
                             verified: { bsonType: "bool" },
                             documents: { bsonType: "array" } } },
      address: { bsonType: "object", required: ["state"],
                 properties: { state: { enum: ["Lagos","Oyo","Ogun","FCT Abuja","Kano","Kaduna",
                                               "Rivers","Edo","Enugu","Anambra","Borno","Plateau"] } } },
      devices:       { bsonType: "array", maxItems: 5 },     // bounded array
      beneficiaries: { bsonType: "array", maxItems: 50 },    // bounded array
      createdAt: { bsonType: "date" }
    } } },
  validationAction: "error"
});

// ---------- accounts: separate collection (balance changes on every txn) ----------
db.createCollection("accounts", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "customerId", "type", "currency", "balance", "status"],
    properties: {
      _id:        { bsonType: "string", pattern: "^[0-9]{10}$", description: "NUBAN account number" },
      customerId: { bsonType: "string" },
      holderName: { bsonType: "string", description: "denormalised for statements/receipts" },
      type:       { enum: ["SAVINGS", "CURRENT", "GL"] },
      currency:   { enum: ["NGN", "USD"] },
      balance:    { bsonType: "decimal" },                   // Decimal128: never use double for money
      status:     { enum: ["ACTIVE", "FROZEN", "CLOSED"] }
    } } }
});

// ---------- transactions: one document per business transaction, legs EMBEDDED ----------
// The ledger legs are always written and read with their transaction -> embed.
db.createCollection("transactions", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "type", "status", "amount", "channel", "legs", "createdAt"],
    properties: {
      _id:     { bsonType: "string", description: "reference / idempotency key" },
      type:    { enum: ["DEPOSIT", "WITHDRAWAL", "TRANSFER", "REVERSAL", "FEE"] },
      status:  { enum: ["PENDING", "COMPLETED", "FAILED", "REVERSED"] },
      amount:  { bsonType: "decimal" },
      channel: { enum: ["MOBILE", "USSD", "WEB", "POS", "ATM", "BRANCH"] },
      legs: { bsonType: "array", minItems: 0, maxItems: 4, items: {
                bsonType: "object", required: ["account", "dir", "amount"],
                properties: { account: { bsonType: "string" }, dir: { enum: ["D", "C"] },
                              amount: { bsonType: "decimal" } } } },
      meta:      { bsonType: "object", description: "flexible: device, geo, POS terminal, NIBSS session id ..." },
      createdAt: { bsonType: "date" }
    } } }
});

// ---------- statements: BUCKET pattern, one document per account per month ----------
// Serves the "History" screen with a single document read instead of N rows.
db.createCollection("statements");

print("Collections created:", db.getCollectionNames().sort().join(", "));
printjson(db.getCollectionInfos({ name: "accounts" })[0].options.validator);
