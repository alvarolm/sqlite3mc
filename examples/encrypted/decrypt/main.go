// Independent decrypt of an SQLite3MC AEGIS-256X4 encrypted database, using
// only github.com/aegis-aead/go-libaegis + golang.org/x/crypto/argon2.
// No SQLite involved — proves the data really is on disk, just opaque without
// the key.
//
//	go run . [path-to-db] [passphrase] [needle]
//
// All three args optional; defaults match the writer in the parent dir.
//
// Layout reverse-engineered from sqlite3/csrc/cipher_aegis.c:
//
//	page 1: [16B salt][n bytes ciphertext][32B tag][32B per-page nonce]
//	other:  [n bytes ciphertext][32B tag][32B per-page nonce]   (n = pageSize - 64)
//
// Decrypt recipe per page:
//  1. masterKey = Argon2id(passphrase, salt, t=2, m=19MiB, p=1, len=32)   (cipher_aegis.c:275)
//  2. otk[64]   = aegis256x4_stream(masterKey, perPageNonce)               (cipher_aegis.c:299, AegisGenOtk)
//     then patch otk[60..64] with bigendian(pageNumber)        (cipher_aegis.c:304)
//  3. plaintext = aegis256x4.Open(key=otk[0:32], nonce=otk[32:64], ciphertext+tag, ad=nil)
package main

/*
#include <stdint.h>
#include <stddef.h>
// go-libaegis only exposes Seal/Open. SQLite3MC needs the raw keystream
// function aegis256x4_stream for its OTK derivation. The symbol is in the
// linked binary because go-libaegis's cgo build compiles the bundled
// libaegis sources; we just declare it extern here and call it directly.
//   declaration: go-libaegis/common/libaegis/src/include/aegis256x4.h:208
extern void aegis256x4_stream(uint8_t *out, size_t len, const uint8_t *npub, const uint8_t *k);
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"unsafe"

	"github.com/aegis-aead/go-libaegis/aegis256x4"
	"golang.org/x/crypto/argon2"
)

const (
	pageSize        = 4096
	saltLen         = 16
	tagLen          = 32
	nonceLen        = 32
	keyLen          = 32
	page1HeaderSkip = 24 // CIPHER_PAGE1_OFFSET — bytes [0..16) are the salt, [16..24) are cleartext SQLite header fields (page size, format versions, reserved-bytes-per-page), [24..) is encrypted
	argon2T         = 2
	argon2M         = 19 * 1024
	argon2P         = 1
)

func main() {
	dbPath := filepath.Join(os.TempDir(), "sqlite3mc-example.db")
	password := "correct horse battery staple"
	needle := "encrypted at rest — needle in the haystack"
	if len(os.Args) > 1 {
		dbPath = os.Args[1]
	}
	if len(os.Args) > 2 {
		password = os.Args[2]
	}
	if len(os.Args) > 3 {
		needle = os.Args[3]
	}

	raw, err := os.ReadFile(dbPath)
	if err != nil {
		log.Fatalf("read %s: %v", dbPath, err)
	}
	if len(raw) < pageSize {
		log.Fatalf("file too small (%d bytes)", len(raw))
	}
	nPages := len(raw) / pageSize
	salt := raw[:saltLen] // KDF salt is in page 1 first 16 bytes
	masterKey := argon2.IDKey([]byte(password), salt, argon2T, argon2M, argon2P, keyLen)

	for p := 1; p <= nPages; p++ {
		plain := decryptPage(raw, masterKey, p)
		fmt.Printf("page %d: decrypted %d bytes", p, len(plain))
		if i := bytes.Index(plain, []byte(needle)); i >= 0 {
			fmt.Printf("  ← found needle at offset %d\n", i)
			fmt.Printf("✓ recovered plaintext from raw bytes via go-libaegis: %q\n", needle)
			return
		}
		fmt.Println()
	}
	log.Fatalf("needle %q not found in any of the %d decrypted pages", needle, nPages)
}

func decryptPage(raw, masterKey []byte, pageNum int) []byte {
	pageStart := (pageNum - 1) * pageSize
	page := raw[pageStart : pageStart+pageSize]
	bodyEnd := pageSize - tagLen - nonceLen
	bodyStart := 0
	if pageNum == 1 {
		bodyStart = page1HeaderSkip
	}
	ciphertext := page[bodyStart:bodyEnd]
	tag := page[bodyEnd : bodyEnd+tagLen]
	perPageNonce := page[bodyEnd+tagLen:]

	otk := make([]byte, keyLen+nonceLen)
	C.aegis256x4_stream(
		(*C.uint8_t)(unsafe.Pointer(&otk[0])), C.size_t(len(otk)),
		(*C.uint8_t)(unsafe.Pointer(&perPageNonce[0])),
		(*C.uint8_t)(unsafe.Pointer(&masterKey[0])),
	)
	binary.BigEndian.PutUint32(otk[len(otk)-4:], uint32(pageNum))

	aead, err := aegis256x4.New(otk[:keyLen], tagLen)
	if err != nil {
		log.Fatalf("aegis New: %v", err)
	}
	combined := append(append(make([]byte, 0, len(ciphertext)+tagLen), ciphertext...), tag...)
	plain, err := aead.Open(nil, otk[keyLen:], combined, nil)
	if err != nil {
		log.Fatalf("aegis Open page %d failed: %v", pageNum, err)
	}
	return plain
}
