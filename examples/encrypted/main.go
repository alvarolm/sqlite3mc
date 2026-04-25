// Encrypted SQLite roundtrip + on-disk proof, using AEGIS-256X4 (the highest
// security tier in the AEGIS family — 256-bit key, 256-bit nonce, AES-NI / AVX2
// / AVX-512 / ARM-crypto / AltiVec / portable software fallback all shipped):
//
//   1. write a row to a passphrase-encrypted database,
//   2. reopen with the same key, read it back,
//   3. open with the wrong key — must fail,
//   4. inspect raw bytes to confirm the file is not a plaintext SQLite DB and
//      that the inserted plaintext does not appear anywhere on disk,
//   5. spawn ./decrypt — a separate Go module that uses
//      github.com/aegis-aead/go-libaegis to decrypt page 1 directly from the
//      raw bytes and recover the plaintext.
//
// Step 5 lives in its own module because go-libaegis bundles the libaegis C
// source, and so does SQLite3MC (under sqlite3/csrc/aegis/) — linking both
// into a single binary causes "multiple definition" errors. Two binaries side
// by side avoid the collision.
//
//	go run .
package main

import (
	"bytes"
	"database/sql"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	sqlite3 "github.com/alvarolm/sqlite3mc/sqlite3"
)

const (
	passphrase = "correct horse battery staple"
	plaintext  = "encrypted at rest — needle in the haystack"

	// Cipher + variant are set via URI parameters; SQLite3MC reads them
	// before any page is touched, so PreConnectHook only has to install
	// the key. See sqlite3/csrc/cipher_config.c:760-870 for the parser
	// and cipher_aegis.c:26-31 for the algorithm IDs (4=256, 5=256X2,
	// 6=256X4 — the highest-tier AEGIS variant).
	cipherURI = "?cipher=aegis&algorithm=aegis-256x4"
)

// "SQLite format 3\x00" — the 16-byte magic at the start of every plaintext DB.
var sqliteMagic = []byte("SQLite format 3\x00")

func main() {
	dbPath := filepath.Join(os.TempDir(), "sqlite3mc-example.db")
	_ = os.Remove(dbPath)
	dsn := "file:" + dbPath + cipherURI

	registerDriver("sqlite3-enc", passphrase)

	// 1. Create + insert.
	db, err := sql.Open("sqlite3-enc", dsn)
	must(err)
	_, err = db.Exec(`CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)`)
	must(err)
	_, err = db.Exec(`INSERT INTO notes(body) VALUES(?)`, plaintext)
	must(err)
	must(db.Close())
	fmt.Printf("wrote encrypted DB at %s (cipher: AEGIS-256X4)\n", dbPath)

	// 2. Reopen with the same key — should succeed.
	db, err = sql.Open("sqlite3-enc", dsn)
	must(err)
	var body string
	must(db.QueryRow(`SELECT body FROM notes LIMIT 1`).Scan(&body))
	fmt.Printf("read back:           %q\n", body)

	// Confirm the active cipher is what we asked for.
	var cipher string
	must(db.QueryRow(`SELECT sqlite3mc_config('cipher')`).Scan(&cipher))
	fmt.Printf("active cipher:       %s\n", cipher)
	if cipher != "aegis" {
		log.Fatalf("expected aegis, got %q", cipher)
	}
	must(db.Close())

	// 3. Open with the wrong key — should fail at the first read.
	registerDriver("sqlite3-bad", "wrong passphrase")
	db, err = sql.Open("sqlite3-bad", dsn)
	must(err)
	_, err = db.Exec(`SELECT 1 FROM notes`)
	if err == nil {
		log.Fatal("expected failure with wrong key, got nil")
	}
	fmt.Printf("wrong key rejected:  %v\n", err)
	_ = db.Close()

	// 4. Bytewise proof — a normal SQLite DB starts with "SQLite format 3\x00".
	raw, err := os.ReadFile(dbPath)
	must(err)
	first16 := raw[:16]
	fmt.Println()
	fmt.Println("on-disk proof")
	fmt.Println("─────────────")
	fmt.Printf("first 16 bytes:      %s   %q\n", hex.EncodeToString(first16), string(first16))
	fmt.Printf("plaintext SQLite hdr %s   %q\n", hex.EncodeToString(sqliteMagic), string(sqliteMagic))
	if bytes.HasPrefix(raw, sqliteMagic) {
		log.Fatal("FAIL: file starts with plaintext SQLite header — not encrypted!")
	}
	fmt.Println("✓ file does NOT start with the plaintext SQLite header")

	if bytes.Contains(raw, []byte(plaintext)) {
		log.Fatalf("FAIL: plaintext %q found in raw bytes — not encrypted!", plaintext)
	}
	fmt.Printf("✓ plaintext %q not present anywhere in the %d-byte file\n", plaintext, len(raw))

	// 5. Spawn the sibling go-libaegis decrypter to recover the plaintext from
	//    the raw bytes — no SQLite involvement.
	fmt.Println()
	fmt.Println("independent decrypt with go-libaegis")
	fmt.Println("─────────────────────────────────────")
	cmd := exec.Command("go", "run", ".", dbPath, passphrase, plaintext)
	cmd.Dir = "decrypt" // sibling module — has its own go.mod
	out, err := cmd.CombinedOutput()
	fmt.Print(string(out))
	if err != nil {
		log.Fatalf("decrypt failed: %v", err)
	}

	fmt.Printf("\ninspect yourself:    xxd %s | head\n", dbPath)
}

func registerDriver(name, key string) {
	sql.Register(name, &sqlite3.SQLiteDriver{
		// PreConnectHook fires BEFORE mattn issues its built-in PRAGMAs
		// (busy_timeout, locking_mode, journal_mode, ...) — the only safe
		// spot to install the codec key, since locking_mode triggers a
		// page-1 read that fails on an encrypted file with no key set.
		PreConnectHook: func(c *sqlite3.SQLiteConn) error {
			stmt := fmt.Sprintf("PRAGMA key = '%s'", strings.ReplaceAll(key, "'", "''"))
			_, err := c.Exec(stmt, nil)
			return err
		},
	})
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
