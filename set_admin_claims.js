/**
 * set_admin_claims.js
 * ─────────────────────────────────────────────────────────────
 * Run this ONE TIME to assign admin custom claims to your 2
 * admin Firebase accounts.
 *
 * STEPS:
 *  1. npm install firebase-admin
 *  2. Download your service account key from Firebase Console
 *     → Project Settings → Service Accounts → Generate new private key
 *  3. Replace the values below
 *  4. node set_admin_claims.js
 * ─────────────────────────────────────────────────────────────
 */

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json'); // your downloaded key

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const ADMIN_UIDS = [
  'Uqjnl5dO7oTeCP92vD05Yw1I3iv1',   // ← paste UID from Firebase Console
  //'REPLACE_WITH_ADMIN_2_UID',   // ← paste UID from Firebase Console
];

async function setAdminClaims() {
  for (const uid of ADMIN_UIDS) {
    await admin.auth().setCustomUserClaims(uid, { role: 'admin' });
    console.log(`✅ Admin claim set for UID: ${uid}`);
  }
  console.log('\n🎉 Done! Both admin accounts are now configured.');
  console.log('These users will be routed to the Admin Dashboard on login.');
  process.exit(0);
}

setAdminClaims().catch((err) => {
  console.error('❌ Error setting claims:', err);
  process.exit(1);
});
