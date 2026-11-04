package protobuf

// This file is not part of protowire. It reads and edits one message by
// field number, for code that has no generated types. Its methods panic on
// malformed input and on a field read with the wrong wire type, so a realm
// aborts instead of acting on bad data. Use the Consume functions to handle
// errors instead.

// Message is an encoded message whose fields are read by number. Read
// returns a valid one, and the zero Message has no fields.
type Message struct {
	b      []byte
	fields []field // in wire order
}

// field locates one record of b: b[start:end] is the whole record and
// b[val:end] its value.
type field struct {
	num             Number
	typ             Type
	start, val, end int
}

// Read parses b once, checking that it is a sequence of well formed
// fields, and returns it as a Message. It does not copy b.
func Read(b []byte) Message {
	m := Message{b: b}
	for pos := 0; pos < len(b); {
		num, typ, n, size := fastField(b[pos:])
		if n == 0 {
			num, typ, n = ConsumeTag(b[pos:])
			if n < 0 {
				panic(ParseError(n).Error())
			}
			size = ConsumeFieldValue(num, typ, b[pos+n:])
			if size < 0 {
				panic(ParseError(size).Error())
			}
		}
		end := pos + n + size
		m.fields = append(m.fields, field{num, typ, pos, pos + n, end})
		pos = end
	}
	return m
}

// fastField parses the common record with a one byte tag and a one byte
// varint or length, without the calls ConsumeTag and ConsumeFieldValue make.
// It returns n == 0 for any other record.
func fastField(b []byte) (num Number, typ Type, n, size int) {
	if len(b) < 2 || b[0] >= 0x80 || b[0] < 8 || b[1] >= 0x80 {
		return 0, 0, 0, 0
	}
	num, typ = Number(b[0]>>3), Type(b[0]&7)
	switch typ {
	case VarintType:
		return num, typ, 1, 1
	case BytesType:
		if int(b[1]) <= len(b)-2 {
			return num, typ, 1, 1 + int(b[1])
		}
	}
	return 0, 0, 0, 0
}

// Has reports whether the message holds field num.
func (m Message) Has(num Number) bool {
	for _, f := range m.fields {
		if f.num == num {
			return true
		}
	}
	return false
}

// value returns the value of the last occurrence of num, which must have
// wire type typ. The last one wins, as the spec requires for a non-repeated
// field.
func (m Message) value(num Number, typ Type) ([]byte, bool) {
	for i := len(m.fields) - 1; i >= 0; i-- {
		f := m.fields[i]
		if f.num != num {
			continue
		}
		if f.typ != typ {
			panic("protobuf: field has another wire type")
		}
		return m.b[f.val:f.end], true
	}
	return nil, false
}

func (m Message) varint(num Number) uint64 {
	v, ok := m.value(num, VarintType)
	if !ok {
		return 0
	}
	x, _ := ConsumeVarint(v)
	return x
}

func (m Message) bytes(num Number) []byte {
	v, ok := m.value(num, BytesType)
	if !ok {
		return nil
	}
	x, _ := ConsumeBytes(v)
	return x
}

// The getters below return the default value of a missing field.

// Int64 reads an int64 field.
func (m Message) Int64(num Number) int64 { return int64(m.varint(num)) }

// Sint64 reads a ZigZag encoded sint64 field.
func (m Message) Sint64(num Number) int64 { return DecodeZigZag(m.varint(num)) }

// Uint64 reads a uint64 field.
func (m Message) Uint64(num Number) uint64 { return m.varint(num) }

// Bool reads a bool field.
func (m Message) Bool(num Number) bool { return DecodeBool(m.varint(num)) }

// String reads a string field.
func (m Message) String(num Number) string { return string(m.bytes(num)) }

// Bytes reads a bytes field. It returns a copy, so the result may be
// changed even when the message is readonly.
func (m Message) Bytes(num Number) []byte {
	b := m.bytes(num)
	if b == nil {
		return nil
	}
	return append([]byte(nil), b...)
}

// Message reads an embedded message field.
func (m Message) Message(num Number) Message { return Read(m.bytes(num)) }

// Editor builds a message from an old one. The fields it writes replace
// every occurrence of the same field number in the old message, and every
// other field of the old message is kept as is. A field this code does not
// know is kept the same way, which is how the spec treats unknown fields.
type Editor struct {
	old     Message
	buf     []byte
	written []Number
}

// Edit returns an Editor that starts from old. Pass nil to build a new
// message.
func Edit(old []byte) *Editor { return Read(old).Edit() }

// Edit returns an Editor that starts from m, without parsing it again.
func (m Message) Edit() *Editor { return &Editor{old: m} }

func (e *Editor) tag(num Number, typ Type) {
	if !num.IsValid() {
		panic("protobuf: invalid field number")
	}
	e.buf = AppendTag(e.buf, num, typ)
	e.written = append(e.written, num)
}

// The setters below always write the field, even a zero value, so a
// reader can tell a zero from a missing field with Has.

func (e *Editor) Int64(num Number, v int64) {
	e.tag(num, VarintType)
	e.buf = AppendVarint(e.buf, uint64(v))
}

func (e *Editor) Sint64(num Number, v int64) {
	e.tag(num, VarintType)
	e.buf = AppendVarint(e.buf, EncodeZigZag(v))
}

func (e *Editor) Uint64(num Number, v uint64) {
	e.tag(num, VarintType)
	e.buf = AppendVarint(e.buf, v)
}

func (e *Editor) Bool(num Number, v bool) {
	e.tag(num, VarintType)
	e.buf = AppendVarint(e.buf, EncodeBool(v))
}

func (e *Editor) String(num Number, v string) {
	e.tag(num, BytesType)
	e.buf = AppendString(e.buf, v)
}

func (e *Editor) Bytes(num Number, v []byte) {
	e.tag(num, BytesType)
	e.buf = AppendBytes(e.buf, v)
}

// Message writes an embedded message, such as the result of another
// Editor's Encode.
func (e *Editor) Message(num Number, v []byte) { e.Bytes(num, v) }

// Encode returns the written fields followed by the old fields that were
// not written. It builds a new slice, so the old message may be readonly.
func (e *Editor) Encode() []byte {
	out := append([]byte(nil), e.buf...)
	for _, f := range e.old.fields {
		if !e.wrote(f.num) {
			out = append(out, e.old.b[f.start:f.end]...)
		}
	}
	return out
}

func (e *Editor) wrote(num Number) bool {
	for _, w := range e.written {
		if w == num {
			return true
		}
	}
	return false
}
