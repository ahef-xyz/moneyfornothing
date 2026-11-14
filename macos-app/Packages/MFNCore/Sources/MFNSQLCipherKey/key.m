#include "MFNSQLCipherKey.h"
#include <SQLCipher/sqlite3.h>

int mfn_sqlcipher_key(sqlite3 *db, const void *key, int length) {
    return sqlite3_key(db, key, length);
}
