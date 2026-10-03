package gopeed

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"go.etcd.io/bbolt"
	"os"
	"path/filepath"
	"time"
)

// Gopeed's normal task store includes signed URLs and Cookie headers. Encrypt every
// value with an Android Keystore-protected key before it is written to disk.
type encryptedStorage struct {
	db  *bbolt.DB
	box cipher.AEAD
}

func newEncryptedStorage(dir string, key []byte) (*encryptedStorage, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	box, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	db, err := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, &bbolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	return &encryptedStorage{db, box}, nil
}
func (s *encryptedStorage) Setup(names []string) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		for _, name := range names {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *encryptedStorage) decode(bucket, key string, data []byte, out any) error {
	if len(data) < s.box.NonceSize()+s.box.Overhead() {
		return errors.New("invalid encrypted download state")
	}
	plain, err := s.box.Open(nil, data[:s.box.NonceSize()], data[s.box.NonceSize():], []byte(bucket+"\x00"+key))
	if err != nil {
		return errors.New("cannot decrypt download state")
	}
	return json.Unmarshal(plain, out)
}
func (s *encryptedStorage) Put(bucket, key string, value any) error {
	plain, err := json.Marshal(value)
	if err != nil {
		return err
	}
	nonce := make([]byte, s.box.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	data := s.box.Seal(nonce, nonce, plain, []byte(bucket+"\x00"+key))
	return s.db.Update(func(tx *bbolt.Tx) error { return tx.Bucket([]byte(bucket)).Put([]byte(key), data) })
}
func (s *encryptedStorage) Get(bucket, key string, out any) (found bool, err error) {
	err = s.db.View(func(tx *bbolt.Tx) error {
		data := tx.Bucket([]byte(bucket)).Get([]byte(key))
		if data == nil {
			return nil
		}
		found = true
		return s.decode(bucket, key, data, out)
	})
	return
}
func (s *encryptedStorage) List(bucket string, out any) error {
	values := make([]json.RawMessage, 0)
	err := s.db.View(func(tx *bbolt.Tx) error {
		return tx.Bucket([]byte(bucket)).ForEach(func(key, data []byte) error {
			var value json.RawMessage
			if err := s.decode(bucket, string(key), data, &value); err != nil {
				return err
			}
			values = append(values, value)
			return nil
		})
	})
	if err != nil {
		return err
	}
	data, err := json.Marshal(values)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}
func (s *encryptedStorage) Pop(bucket, key string, out any) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		data := b.Get([]byte(key))
		if data == nil {
			return nil
		}
		if err := s.decode(bucket, key, data, out); err != nil {
			return err
		}
		// Retain the last durable checkpoint until a newer one replaces it. A process
		// killed immediately after resume must still have its saved range positions.
		return nil
	})
}
func (s *encryptedStorage) Delete(bucket, key string) error {
	return s.db.Update(func(tx *bbolt.Tx) error { return tx.Bucket([]byte(bucket)).Delete([]byte(key)) })
}
func (s *encryptedStorage) Clear() error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		var names [][]byte
		if err := tx.ForEach(func(name []byte, _ *bbolt.Bucket) error {
			names = append(names, append([]byte(nil), name...))
			return nil
		}); err != nil {
			return err
		}
		for _, name := range names {
			if err := tx.DeleteBucket(name); err != nil {
				return err
			}
			if _, err := tx.CreateBucket(name); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *encryptedStorage) Close() error { return s.db.Close() }
