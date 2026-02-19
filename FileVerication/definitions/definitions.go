package definitions

import (
	"encoding/xml"
	"strconv"
)

type Objs struct {
	XMLName xml.Name `xml:"Objs"`
	Objects []Obj    `xml:"Obj"`
}

type Obj struct {
	RefID int     `xml:"RefId,attr"`
	Name  string  `xml:"N,attr,omitempty"`
	MS    *Member `xml:"MS"`
	LST   *List   `xml:"LST"`
	DCT   *Dict   `xml:"DCT"`
}

type Member struct {
	Strings   []NamedString `xml:"S"`
	Int32s    []NamedInt32  `xml:"I32"`
	Objs      []Obj         `xml:"Obj"`
	Algorithm string        `xml:"-"`
}

func (m *Member) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	*m = Member{}

	for {
		tok, err := d.Token()
		if err != nil {
			return err
		}

		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "S":
				var ns NamedString
				if err := d.DecodeElement(&ns, &t); err != nil {
					return err
				}
				m.Strings = append(m.Strings, ns)
				if ns.Name == "algorithm" {
					m.Algorithm = ns.Value
				}
			case "I32":
				var ni NamedInt32
				if err := d.DecodeElement(&ni, &t); err != nil {
					return err
				}
				m.Int32s = append(m.Int32s, ni)
			case "Obj":
				var o Obj
				if err := d.DecodeElement(&o, &t); err != nil {
					return err
				}
				m.Objs = append(m.Objs, o)
			default:
				if err := d.Skip(); err != nil {
					return err
				}
			}
		case xml.EndElement:
			if t.Name.Local == start.Name.Local {
				return nil
			}
		}
	}
}

type NamedString struct {
	Name  string `xml:"N,attr"`
	Value string `xml:",chardata"`
}

type NamedInt32 struct {
	Name  string `xml:"N,attr"`
	Value int32  `xml:",chardata"`
}

type List struct {
	Items []Obj `xml:"Obj"`
}

type Dict struct {
	Entries []En `xml:"En"`
}

type En struct {
	Fields []Field `xml:",any"`
}

type Field struct {
	XMLName xml.Name
	N       string `xml:"N,attr"`
	Text    string `xml:",chardata"`
}

func (e En) KeyValue() (key string, val any, ok bool, err error) {
	var keyFound, valFound bool
	var valTag string
	var valText string

	for _, f := range e.Fields {
		switch f.N {
		case "Key":
			key = f.Text
			keyFound = true
		case "Value":
			valTag = f.XMLName.Local
			valText = f.Text
			valFound = true
		}
	}

	if !keyFound || !valFound {
		return "", nil, false, nil
	}

	switch valTag {
	case "S":
		val = valText
	case "B":
		val = valText == "true" || valText == "True" || valText == "1"
	case "I64":
		n, parseErr := strconv.ParseInt(valText, 10, 64)
		if parseErr != nil {
			return "", nil, false, parseErr
		}
		val = n
	case "I32":
		n, parseErr := strconv.ParseInt(valText, 10, 32)
		if parseErr != nil {
			return "", nil, false, parseErr
		}
		val = int32(n)
	case "Nil":
		val = nil
	default:
		val = valText
	}

	return key, val, true, nil
}
