#ifndef MFN_SQLCIPHER_KEY_H
#define MFN_SQLCIPHER_KEY_H

typedef struct sqlite3 sqlite3;

/// Calls `sqlite3_key`. `key` is the passphrase buffer (raw-key syntax `x'<hex>'`), `length` its size.
/// The caller wipes the buffer afterwards. Returns an SQLite result code.
int mfn_sqlcipher_key(sqlite3 *db, const void *key, int length);

#endif
