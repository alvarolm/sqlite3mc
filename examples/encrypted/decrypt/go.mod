// Separate module so its libaegis copy doesn't collide with SQLite3MC's bundled
// libaegis at link time. Built and run as `cd decrypt && go run .`.
module github.com/alvarolm/sqlite3mc/examples/encrypted/decrypt

go 1.25.0

require (
	github.com/aegis-aead/go-libaegis v0.2.14
	golang.org/x/crypto v0.50.0
)

require golang.org/x/sys v0.43.0 // indirect
