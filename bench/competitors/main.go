// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/rawbytes"
	"github.com/knadh/koanf/v2"
	"github.com/spf13/viper"
)

const samples = 7

type lookupFixture struct {
	name   string
	fields int
	mode   string
}

var lookups = []lookupFixture{
	{"lookup-small", 8, "first"},
	{"lookup-mixed-wide", 256, "mixed"},
	{"lookup-last-wide", 256, "last"},
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 1 && args[0] == "metadata" {
		return metadata()
	}
	if len(args) < 1 || len(args) > 2 || (args[0] != "viper" && args[0] != "koanf") {
		return fmt.Errorf("usage: competitors {viper|koanf} [count:1..100000] | metadata")
	}
	count := 1000
	if len(args) == 2 {
		var err error
		count, err = strconv.Atoi(args[1])
		if err != nil || count < 1 || count > 100000 {
			return fmt.Errorf("count must be an integer from 1 through 100000")
		}
	}
	for _, fixture := range lookups {
		var err error
		if args[0] == "viper" {
			err = lookupViper(fixture, count)
		} else {
			err = lookupKoanf(fixture, count)
		}
		if err != nil {
			return err
		}
	}
	if args[0] == "viper" {
		return tomlViper(count)
	}
	return tomlKoanf(count)
}

func keysFor(f lookupFixture) []string {
	keys := make([]string, f.fields)
	for i := range keys {
		keys[i] = fmt.Sprintf("field%d", i)
	}
	return keys
}

func lookupViper(f lookupFixture, count int) error {
	keys := keysFor(f)
	payload := strings.Repeat("x", 32)
	v := viper.New()
	for _, key := range keys {
		v.Set(key, payload)
	}
	first, last := keys[0], keys[len(keys)-1]
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			var value string
			switch f.mode {
			case "mixed":
				value = v.GetString(keys[(i*73)%f.fields])
			case "last":
				value = v.GetString(last)
			default:
				value = v.GetString(first)
			}
			checksum += int64(len(value))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	for _, key := range keys {
		if value := v.GetString(key); value != payload {
			return fmt.Errorf("viper %s: %s = %q, expected %q", f.name, key, value, payload)
		}
	}
	return report(f.name, times, checksum, int64(samples*count*32))
}

func lookupKoanf(f lookupFixture, count int) error {
	keys := keysFor(f)
	payload := strings.Repeat("x", 32)
	k := koanf.New(".")
	for _, key := range keys {
		if err := k.Set(key, payload); err != nil {
			return fmt.Errorf("koanf %s setup: %w", f.name, err)
		}
	}
	first, last := keys[0], keys[len(keys)-1]
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			var value string
			switch f.mode {
			case "mixed":
				value = k.String(keys[(i*73)%f.fields])
			case "last":
				value = k.String(last)
			default:
				value = k.String(first)
			}
			checksum += int64(len(value))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	for _, key := range keys {
		if value := k.String(key); value != payload {
			return fmt.Errorf("koanf %s: %s = %q, expected %q", f.name, key, value, payload)
		}
	}
	return report(f.name, times, checksum, int64(samples*count*32))
}

func tomlDocuments() [2][]byte {
	return [2][]byte{
		[]byte("name='goose'\n[server]\nport=8080"),
		[]byte("name='duck'\n[server]\nport=9000"),
	}
}

func expectedTOML(count int) (string, int64, int64) {
	name, port := "goose", int64(8080)
	if count%2 == 0 {
		name, port = "duck", 9000
	}
	checksum := int64(samples) * (int64((count+1)/2)*8080 + int64(count/2)*9000)
	return name, port, checksum
}

func tomlViper(count int) error {
	docs := tomlDocuments()
	v := viper.New()
	v.SetConfigType("toml")
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			if err := v.MergeConfig(bytes.NewReader(docs[i%2])); err != nil {
				return fmt.Errorf("viper toml-small load: %w", err)
			}
			checksum += v.GetInt64("server.port")
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	name, port, expected := expectedTOML(count)
	if v.GetString("name") != name || v.GetInt64("server.port") != port {
		return fmt.Errorf("viper toml-small: final name/port mismatch")
	}
	return report("toml-small", times, checksum, expected)
}

func tomlKoanf(count int) error {
	docs := tomlDocuments()
	k := koanf.New(".")
	parser := toml.Parser()
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			if err := k.Load(rawbytes.Provider(docs[i%2]), parser); err != nil {
				return fmt.Errorf("koanf toml-small load: %w", err)
			}
			checksum += k.Int64("server.port")
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	name, port, expected := expectedTOML(count)
	if k.String("name") != name || k.Int64("server.port") != port {
		return fmt.Errorf("koanf toml-small: final name/port mismatch")
	}
	return report("toml-small", times, checksum, expected)
}

func report(name string, times [samples]float64, checksum, expected int64) error {
	if checksum != expected {
		return fmt.Errorf("%s checksum = %d, expected %d", name, checksum, expected)
	}
	encoded, err := json.Marshal(times)
	if err != nil {
		return err
	}
	fmt.Printf("%s samples_ns=%s checksum=%d\n", name, encoded, checksum)
	return nil
}

func metadata() error {
	build, ok := debug.ReadBuildInfo()
	if !ok {
		return fmt.Errorf("Go build information unavailable")
	}
	dependencies := make(map[string]string, len(build.Deps))
	for _, dep := range build.Deps {
		if dep.Replace != nil {
			return fmt.Errorf("replacement dependency %s makes version provenance ambiguous", dep.Path)
		}
		dependencies[dep.Path] = dep.Version
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"go_version":     runtime.Version(),
		"goos":           runtime.GOOS,
		"goarch":         runtime.GOARCH,
		"gomaxprocs":     runtime.GOMAXPROCS(0),
		"dependencies":   dependencies,
		"build_settings": build.Settings,
		"samples":        samples,
		"source_labels":  "unsupported: neither adapter tracks Goose per-setting source labels",
		"semantic_limitations": []string{
			"Shared successful lookup and TOML subset only; not feature equivalence.",
			"No Goose schema declaration, strict kind errors, or atomic rejected-layer behavior is supplied by these adapter paths.",
			"Typed getters have different conversion and missing-value behavior; fixtures use present values of matching types.",
			"Final values are checked outside timing; source labels cannot be verified and are not reconstructed.",
		},
	})
}
