package backup

import (
	"encoding/json"
	"reflect"
	"strings"
)

// rawAlias captures a JSON value as a sub-slice of the input, without copying it (json.RawMessage copies).
// Request lines hold key material, and the line buffer is wiped after each request; an alias leaves no second
// copy behind. Only valid while the input buffer is.
type rawAlias []byte

func (r *rawAlias) UnmarshalJSON(data []byte) error {
	*r = data
	return nil
}

// strictUnmarshal decodes raw into `into` (a pointer to a struct) and refuses fields the struct doesn't declare, at
// every nesting level. It avoids json.Decoder, which copies its input into an internal buffer nobody can wipe.
func strictUnmarshal(raw []byte, into any) error {
	if err := checkFields(raw, reflect.TypeOf(into).Elem(), ""); err != nil {
		return err
	}
	return json.Unmarshal(raw, into)
}

type unknownFieldError struct{ name string }

func (e unknownFieldError) Error() string { return "json: unknown field \"" + e.name + "\"" }

func checkFields(raw []byte, t reflect.Type, path string) error {
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	switch t.Kind() {
	case reflect.Struct:
		if string(raw) == "null" {
			return nil
		}
		var obj map[string]rawAlias
		if err := json.Unmarshal(raw, &obj); err != nil {
			return err
		}
		fields := map[string]reflect.StructField{}
		for i := range t.NumField() {
			f := t.Field(i)
			name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
			if name == "" || name == "-" {
				continue
			}
			fields[name] = f
		}
		for name, value := range obj {
			f, ok := fields[name]
			if !ok {
				return unknownFieldError{path + name}
			}
			if err := checkFields(value, f.Type, path+name+"."); err != nil {
				return err
			}
		}
	case reflect.Slice:
		if t.Elem().Kind() != reflect.Struct || string(raw) == "null" {
			return nil
		}
		var items []rawAlias
		if err := json.Unmarshal(raw, &items); err != nil {
			return err
		}
		for _, item := range items {
			if err := checkFields(item, t.Elem(), path); err != nil {
				return err
			}
		}
	}
	return nil
}
