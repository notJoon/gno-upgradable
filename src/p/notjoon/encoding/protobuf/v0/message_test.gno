package protobuf

import (
	"encoding/hex"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// The examples from the encoding guide, docs/spec/protobuf/encoding.md.
func TestSpecExamples(t *testing.T) {
	e := Edit(nil)
	e.Int64(1, 150) // message Test1 { int32 a = 1; }
	test1 := e.Encode()
	uassert.Equal(t, "089601", hex.EncodeToString(test1))
	uassert.Equal(t, int64(150), Read(test1).Int64(1))

	e = Edit(nil)
	e.String(2, "testing") // message Test2 { string b = 2; }
	uassert.Equal(t, "120774657374696e67", hex.EncodeToString(e.Encode()))

	e = Edit(nil)
	e.Message(3, test1) // message Test3 { Test1 c = 3; }
	test3 := e.Encode()
	uassert.Equal(t, "1a03089601", hex.EncodeToString(test3))
	uassert.Equal(t, int64(150), Read(test3).Message(3).Int64(1))

	// int64 stores negatives in two's complement, so -2 takes ten bytes.
	e = Edit(nil)
	e.Int64(1, -2)
	b := e.Encode()
	uassert.Equal(t, "08feffffffffffffffff01", hex.EncodeToString(b))
	uassert.Equal(t, int64(-2), Read(b).Int64(1))

	// sint64 uses ZigZag, so -2 takes one byte.
	e = Edit(nil)
	e.Sint64(1, -2)
	b = e.Encode()
	uassert.Equal(t, "0803", hex.EncodeToString(b))
	uassert.Equal(t, int64(-2), Read(b).Sint64(1))
}

func TestReadDefaults(t *testing.T) {
	m := Read(nil)
	uassert.False(t, m.Has(1))
	uassert.Equal(t, int64(0), m.Int64(1))
	uassert.Equal(t, uint64(0), m.Uint64(1))
	uassert.False(t, m.Bool(1))
	uassert.Equal(t, "", m.String(1))
	uassert.True(t, m.Bytes(1) == nil)
	uassert.False(t, m.Message(1).Has(1))

	// A zero value is written, so Has tells it from a missing field.
	e := Edit(nil)
	e.Bool(1, false)
	m = Read(e.Encode())
	uassert.True(t, m.Has(1))
	uassert.False(t, m.Has(2))
}

func TestLastOneWins(t *testing.T) {
	b, _ := hex.DecodeString("0896010801") // 1: 150, then 1: 1
	uassert.Equal(t, int64(1), Read(b).Int64(1))
}

// An older version edits a message a newer one extended. The newer field,
// unknown to the older code, survives.
func TestEditKeepsUnknownFields(t *testing.T) {
	v2 := Edit(nil)
	v2.Int64(1, 100)
	v2.String(2, "alice")
	v2.Sint64(3, -7) // added by v2
	b := v2.Encode()

	m := Read(b)
	v1 := Edit(b)
	v1.Int64(1, m.Int64(1)+1)
	v1.String(2, m.String(2))
	b = v1.Encode()

	m = Read(b)
	uassert.Equal(t, int64(101), m.Int64(1))
	uassert.Equal(t, "alice", m.String(2))
	uassert.Equal(t, int64(-7), m.Sint64(3))
	uassert.Equal(t, len(v2.Encode()), len(b))
}

func TestEditReplacesEveryOccurrence(t *testing.T) {
	old, _ := hex.DecodeString("0801100208031004") // 1: 1, 2: 2, 1: 3, 2: 4
	e := Edit(old)
	e.Int64(1, 9)
	b := e.Encode()
	uassert.Equal(t, "080910021004", hex.EncodeToString(b))
	uassert.Equal(t, int64(9), Read(b).Int64(1))
	uassert.Equal(t, int64(4), Read(b).Int64(2))
}

func TestBytesIsACopy(t *testing.T) {
	e := Edit(nil)
	e.Bytes(1, []byte{1})
	b := e.Encode()
	got := Read(b).Bytes(1)
	got[0] = 9
	uassert.Equal(t, "\x01", string(Read(b).Bytes(1)))
}

func TestMalformed(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "unexpected EOF", func() { Read([]byte{0x08}) })
	uassert.PanicsWithMessage(t, cur, "unexpected EOF", func() { Edit([]byte{0x12, 0x05, 'a'}) })
	uassert.PanicsWithMessage(t, cur, "protobuf: invalid field number", func() { Read([]byte{0x00, 0x00}) })

	e := Edit(nil)
	e.Int64(1, 1)
	b := e.Encode()
	uassert.PanicsWithMessage(t, cur, "protobuf: field has another wire type", func() { Read(b).String(1) })
	uassert.PanicsWithMessage(t, cur, "protobuf: invalid field number", func() { Edit(nil).Int64(0, 1) })
}
