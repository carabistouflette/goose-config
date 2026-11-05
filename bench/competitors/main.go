// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	jsonparser "github.com/knadh/koanf/parsers/json"
	"github.com/knadh/koanf/parsers/toml/v2"
	envprovider "github.com/knadh/koanf/providers/env/v2"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/providers/rawbytes"
	"github.com/knadh/koanf/v2"
	"github.com/spf13/pflag"
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
	if len(args) < 1 || len(args) > 3 || (args[0] != "viper" && args[0] != "koanf") || (len(args) == 3 && args[2] != "common" && args[2] != "bindings" && args[2] != "durations") {
		return fmt.Errorf("usage: competitors {viper|koanf} [count:1..100000] [common|bindings|durations] | metadata")
	}
	count := 1000
	if len(args) >= 2 {
		var err error
		count, err = strconv.Atoi(args[1])
		if err != nil || count < 1 || count > 100000 {
			return fmt.Errorf("count must be an integer from 1 through 100000")
		}
	}
	if len(args) == 3 && args[2] == "durations" {
		return durations(args[0], count)
	}
	if len(args) == 3 && args[2] == "bindings" {
		if args[0] == "viper" {
			if err := bindingsViper(count, false); err != nil {
				return err
			}
			if err := bindingsViper(count, true); err != nil {
				return err
			}
			return reloadLayersViper(count)
		}
		if err := bindingsKoanf(count, false); err != nil {
			return err
		}
		if err := bindingsKoanf(count, true); err != nil {
			return err
		}
		return reloadLayersKoanf(count)
	}
	if len(args) == 3 {
		if args[0] == "viper" {
			if err := listsViper("json", count); err != nil {
				return err
			}
			if err := listsViper("toml", count); err != nil {
				return err
			}
			return reloadViper(count)
		}
		if err := listsKoanf("json", count); err != nil {
			return err
		}
		if err := listsKoanf("toml", count); err != nil {
			return err
		}
		return reloadKoanf(count)
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

func listDocuments(format string) [2][]byte {
	if format == "json" {
		return [2][]byte{[]byte(`{"ports":[8080,9000],"tags":["goose","duck"]}`), []byte(`{"ports":[9001],"tags":["duck"]}`)}
	}
	return [2][]byte{[]byte("ports=[8080,9000]\ntags=['goose','duck']"), []byte("ports=[9001]\ntags=['duck']")}
}

func checkLists(count int, ports []int64, tags []string) error {
	if count%2 == 0 {
		if len(ports) != 1 || ports[0] != 9001 || len(tags) != 1 || tags[0] != "duck" {
			return fmt.Errorf("final replacement lists mismatch")
		}
	} else if len(ports) != 2 || ports[0] != 8080 || ports[1] != 9000 || len(tags) != 2 || tags[0] != "goose" || tags[1] != "duck" {
		return fmt.Errorf("final initial lists mismatch")
	}
	return nil
}

func listChecksum(count int) int64 {
	return int64(samples) * (int64((count+1)/2)*8082 + int64(count/2)*9002)
}

func listsViper(format string, count int) error {
	docs := listDocuments(format)
	v := viper.New()
	v.SetConfigType(format)
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			if err := v.MergeConfig(bytes.NewReader(docs[i%2])); err != nil {
				return fmt.Errorf("viper %s-lists load: %w", format, err)
			}
			ports := v.GetIntSlice("ports")
			if len(ports) == 0 {
				return fmt.Errorf("viper %s-lists: empty integer list", format)
			}
			checksum += int64(ports[0] + len(ports))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	actual := v.GetIntSlice("ports")
	ports := make([]int64, len(actual))
	for i, port := range actual {
		ports[i] = int64(port)
	}
	if err := checkLists(count, ports, v.GetStringSlice("tags")); err != nil {
		return fmt.Errorf("viper %s-lists: %w", format, err)
	}
	return report(format+"-lists", times, checksum, listChecksum(count))
}

func listsKoanf(format string, count int) error {
	docs := listDocuments(format)
	k := koanf.New(".")
	var parser koanf.Parser = toml.Parser()
	if format == "json" {
		parser = jsonparser.Parser()
	}
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			if err := k.Load(rawbytes.Provider(docs[i%2]), parser); err != nil {
				return fmt.Errorf("koanf %s-lists load: %w", format, err)
			}
			ports := k.Int64s("ports")
			if len(ports) == 0 {
				return fmt.Errorf("koanf %s-lists: empty integer list", format)
			}
			checksum += ports[0] + int64(len(ports))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkLists(count, k.Int64s("ports"), k.Strings("tags")); err != nil {
		return fmt.Errorf("koanf %s-lists: %w", format, err)
	}
	return report(format+"-lists", times, checksum, listChecksum(count))
}

func reloadDocuments() [2][]byte {
	return [2][]byte{[]byte(`{"port":9000,"name":"file"}`), []byte(`{"name":"edited"}`)}
}

func checkReload(count int, port int64, name string) error {
	wantPort, wantName := int64(9000), "file"
	if count%2 == 0 {
		wantPort, wantName = 8080, "edited"
	}
	if port != wantPort || name != wantName {
		return fmt.Errorf("final replay values: port=%d name=%q, expected %d/%q", port, name, wantPort, wantName)
	}
	return nil
}

func reloadChecksum(count int) int64 {
	return int64(samples) * (int64((count+1)/2)*9000 + int64(count/2)*8080)
}

func reloadViper(count int) error {
	docs := reloadDocuments()
	var v *viper.Viper
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			// Replay current sources from scratch so removed file keys expose defaults.
			v = viper.New()
			v.SetConfigType("json")
			v.SetDefault("port", int64(8080))
			v.SetDefault("name", "default")
			if err := v.ReadConfig(bytes.NewReader(docs[i%2])); err != nil {
				return fmt.Errorf("viper reload-removal: %w", err)
			}
			checksum += v.GetInt64("port")
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkReload(count, v.GetInt64("port"), v.GetString("name")); err != nil {
		return fmt.Errorf("viper reload-removal: %w", err)
	}
	return report("reload-removal", times, checksum, reloadChecksum(count))
}

func reloadKoanf(count int) error {
	docs := reloadDocuments()
	parser := jsonparser.Parser()
	var k *koanf.Koanf
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			k = koanf.New(".")
			if err := k.Set("port", int64(8080)); err != nil {
				return err
			}
			if err := k.Set("name", "default"); err != nil {
				return err
			}
			if err := k.Load(rawbytes.Provider(docs[i%2]), parser); err != nil {
				return fmt.Errorf("koanf reload-removal: %w", err)
			}
			checksum += k.Int64("port")
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkReload(count, k.Int64("port"), k.String("name")); err != nil {
		return fmt.Errorf("koanf reload-removal: %w", err)
	}
	return report("reload-removal", times, checksum, reloadChecksum(count))
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
			"Shared successful lookup, TOML, JSON/list replacement, and current-source replay subsets only; not feature equivalence.",
			"No Goose schema declaration, strict kind errors, or atomic rejected-layer behavior is supplied by these adapter paths.",
			"Typed getters have different conversion and missing-value behavior; fixtures use present values of matching types.",
			"Final values are checked outside timing; source labels cannot be verified and are not reconstructed.",
			"Bindings mode times fresh env/CLI snapshots, including Viper BindEnv/BindPFlags or Koanf env/v2/posflag loads, typed pflag registration/parse, and getters. Viper env getters resolve lazily; Koanf materializes a provider map.",
			"Bindings reload-layers replays defaults plus three current JSON documents, replacing a 256-item list and exposing a lower document after middle port removal. Source labels remain unsupported.",
			"Common list getters are Viper GetIntSlice and Koanf Int64s; their conversion and ownership contracts differ from Goose's strict independently owned i64 arrays.",
			"Common reload-removal creates fresh Viper/Koanf instances and replays defaults plus current JSON per operation; it does not supply Goose's atomic validated reload or retain old snapshots.",
			"Goose enforces integer range 1..65535 in common fixtures; adapters do not implement schema/range validation. All fixture numbers are small exact integers.",
		},
	})
}

// Descriptors are prepared before timing; all registration/parse/load/get work is timed.
var envBindings = [][2]string{{"port", "GOOSE_BENCH_PORT"}, {"name", "GOOSE_BENCH_NAME"}, {"tag", "GOOSE_BENCH_TAG"}}

func bindingFlags(arguments []string) (*pflag.FlagSet, error) {
	flags := pflag.NewFlagSet("fixture", pflag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.Int64("port", 0, "")
	flags.String("name", "", "")
	flags.StringArray("tag", nil, "") // Repeat without comma splitting.
	if err := flags.Parse(arguments); err != nil {
		return nil, err
	}
	return flags, nil
}
func checkBindings(cli bool, port int64, name string, tags []string) error {
	expected := []string{"a", "b", "c"}
	if cli {
		expected = []string{"first", "second"}
	}
	if port != 9000 || name != "worker" || len(tags) != len(expected) {
		return fmt.Errorf("binding final port/name/list length mismatch: %d/%q/%v", port, name, tags)
	}
	for i, tag := range tags {
		if tag != expected[i] {
			return fmt.Errorf("binding tag %d = %q, expected %q", i, tag, expected[i])
		}
	}
	return nil
}
func bindingName(cli bool) string {
	if cli {
		return "cli-lists"
	}
	return "env-bindings"
}
func bindingChecksum(count int, cli bool) int64 {
	width := 3
	if cli {
		width = 2
	}
	return int64(samples) * int64(count) * int64(9000+width+len("worker"))
}
func bindingsViper(count int, cli bool) error {
	arguments := []string{"--port", "9000", "--name", "worker", "--tag", "first", "--tag", "second"}
	var v *viper.Viper
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			v = viper.New()
			if cli {
				flags, err := bindingFlags(arguments)
				if err != nil {
					return err
				}
				if err := v.BindPFlags(flags); err != nil {
					return err
				}
			} else {
				for _, binding := range envBindings {
					if err := v.BindEnv(binding[0], binding[1]); err != nil {
						return err
					}
				}
			}
			checksum += v.GetInt64("port") + int64(len(v.GetStringSlice("tag"))+len(v.GetString("name")))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkBindings(cli, v.GetInt64("port"), v.GetString("name"), v.GetStringSlice("tag")); err != nil {
		return err
	}
	return report(bindingName(cli), times, checksum, bindingChecksum(count, cli))
}
func bindingsKoanf(count int, cli bool) error {
	arguments := []string{"--port", "9000", "--name", "worker", "--tag", "first", "--tag", "second"}
	options := envprovider.Opt{Prefix: "GOOSE_BENCH_", TransformFunc: func(key, value string) (string, any) {
		key = strings.ToLower(strings.TrimPrefix(key, "GOOSE_BENCH_"))
		if key == "tag" {
			return key, strings.Split(value, " ")
		}
		return key, value
	}}
	var k *koanf.Koanf
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			k = koanf.New(".")
			if cli {
				flags, err := bindingFlags(arguments)
				if err != nil {
					return err
				}
				if err := k.Load(posflag.Provider(flags, ".", k), nil); err != nil {
					return err
				}
			} else {
				if err := k.Load(envprovider.Provider(".", options), nil); err != nil {
					return err
				}
			}
			checksum += k.Int64("port") + int64(len(k.Strings("tag"))+len(k.String("name")))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkBindings(cli, k.Int64("port"), k.String("name"), k.Strings("tag")); err != nil {
		return err
	}
	return report(bindingName(cli), times, checksum, bindingChecksum(count, cli))
}
func reloadLayerDocuments() ([2][3][]byte, error) {
	lower, upper := make([]int, 256), make([]int, 256)
	for i := range lower {
		lower[i], upper[i] = i+1, i+1001
	}
	low, err := json.Marshal(struct {
		Port  int    `json:"port"`
		Name  string `json:"name"`
		Ports []int  `json:"ports"`
	}{8100, "lower", lower})
	if err != nil {
		return [2][3][]byte{}, err
	}
	high, err := json.Marshal(map[string]any{"name": "upper", "ports": upper})
	if err != nil {
		return [2][3][]byte{}, err
	}
	return [2][3][]byte{{low, []byte(`{"port":9000,"name":"middle"}`), high},
		{low, []byte(`{"name":"edited"}`), high}}, nil
}
func reloadLayerChecksum(count int) int64 {
	return int64(samples) * (int64((count+1)/2)*(9000+256+5) + int64(count/2)*(8100+256+5))
}
func checkReloadLayers(count int, port int64, name string, ports []int64) error {
	expectedPort := int64(9000)
	if count%2 == 0 {
		expectedPort = 8100
	}
	if port != expectedPort || name != "upper" || len(ports) != 256 {
		return fmt.Errorf("reload-layers final port/name/list length mismatch")
	}
	for i, value := range ports {
		if value != int64(i+1001) {
			return fmt.Errorf("reload-layers item %d = %d", i, value)
		}
	}
	return nil
}
func reloadLayersViper(count int) error {
	docs, err := reloadLayerDocuments()
	if err != nil {
		return err
	}
	var v *viper.Viper
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			v = viper.New()
			v.SetConfigType("json")
			v.SetDefault("port", int64(8080))
			v.SetDefault("name", "default")
			for _, doc := range docs[i%2] {
				if err := v.MergeConfig(bytes.NewReader(doc)); err != nil {
					return err
				}
			}
			checksum += v.GetInt64("port") + int64(len(v.GetIntSlice("ports"))+len(v.GetString("name")))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	actual := v.GetIntSlice("ports")
	ports := make([]int64, len(actual))
	for i, value := range actual {
		ports[i] = int64(value)
	}
	if err := checkReloadLayers(count, v.GetInt64("port"), v.GetString("name"), ports); err != nil {
		return err
	}
	return report("reload-layers", times, checksum, reloadLayerChecksum(count))
}
func reloadLayersKoanf(count int) error {
	docs, err := reloadLayerDocuments()
	if err != nil {
		return err
	}
	parser := jsonparser.Parser()
	var k *koanf.Koanf
	var times [samples]float64
	var checksum int64
	for sample := range times {
		start := time.Now()
		for i := 0; i < count; i++ {
			k = koanf.New(".")
			if err := k.Set("port", int64(8080)); err != nil {
				return err
			}
			if err := k.Set("name", "default"); err != nil {
				return err
			}
			for _, doc := range docs[i%2] {
				if err := k.Load(rawbytes.Provider(doc), parser); err != nil {
					return err
				}
			}
			checksum += k.Int64("port") + int64(len(k.Int64s("ports"))+len(k.String("name")))
		}
		times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
	}
	if err := checkReloadLayers(count, k.Int64("port"), k.String("name"), k.Int64s("ports")); err != nil {
		return err
	}
	return report("reload-layers", times, checksum, reloadLayerChecksum(count))
}

// Valid shared inputs only. CONFIG performs schema/atomicity/provenance work
// that these dynamic getters do not supply. Parsing occurs on different sides
// of the write/get boundary; see docs/duration-performance.md.
func durations(label string, count int) error {
	texts := []string{"250ms", "1.5s"}
	jsonDocuments := []string{`{"delay":"250ms"}`, `{"delay":"1.5s"}`}
	tomlDocuments := []string{"delay='250ms'", "delay='1.5s'"}
	for mode, name := range []string{"duration-get", "duration-override", "duration-json", "duration-toml"} {
		v := viper.New()
		k := koanf.New(".")
		v.SetConfigType(map[bool]string{true: "toml", false: "json"}[mode == 3])
		if label == "viper" {
			v.Set("delay", "250ms")
		} else if err := k.Set("delay", "250ms"); err != nil {
			return err
		}
		// Viper Set overrides file data; clear that initial override for file cases.
		if label == "viper" && mode >= 2 {
			v = viper.New()
			if mode == 2 {
				v.SetConfigType("json")
			} else {
				v.SetConfigType("toml")
			}
		}
		if mode == 0 {
			if label == "viper" {
				v.Set("other", "1.5s")
			} else if err := k.Set("other", "1.5s"); err != nil {
				return err
			}
		}
		var times [samples]float64
		var checksum int64
		for sample := range times {
			start := time.Now()
			for i := 0; i < count; i++ {
				key := "delay"
				if mode == 0 && i%2 == 1 {
					key = "other"
				}
				var err error
				if label == "viper" {
					switch mode {
					case 1:
						v.Set("delay", texts[i%2])
					case 2:
						err = v.ReadConfig(strings.NewReader(jsonDocuments[i%2]))
					case 3:
						err = v.ReadConfig(strings.NewReader(tomlDocuments[i%2]))
					}
					if err != nil {
						return err
					}
					checksum += int64(v.GetDuration(key))
				} else {
					switch mode {
					case 1:
						err = k.Set("delay", texts[i%2])
					case 2:
						err = k.Load(rawbytes.Provider([]byte(jsonDocuments[i%2])), jsonparser.Parser())
					case 3:
						err = k.Load(rawbytes.Provider([]byte(tomlDocuments[i%2])), toml.Parser())
					}
					if err != nil {
						return err
					}
					checksum += int64(k.Duration(key))
				}
			}
			times[sample] = float64(time.Since(start).Nanoseconds()) / float64(count)
		}
		expected := int64(samples) * (int64((count+1)/2)*250000000 + int64(count/2)*1500000000)
		final := time.Duration(250000000)
		if mode != 0 && count%2 == 0 {
			final = 1500000000
		}
		if label == "viper" {
			if v.GetDuration("delay") != final || len(v.AllSettings()) != map[bool]int{true: 2, false: 1}[mode == 0] {
				return fmt.Errorf("viper duration final mismatch")
			}
		} else {
			if k.Duration("delay") != final || len(k.All()) != map[bool]int{true: 2, false: 1}[mode == 0] {
				return fmt.Errorf("koanf duration final mismatch")
			}
		}
		if mode == 0 && ((label == "viper" && v.GetDuration("other") != 1500000000) || (label == "koanf" && k.Duration("other") != 1500000000)) {
			return fmt.Errorf("duration other final mismatch")
		}
		if err := report(name, times, checksum, expected); err != nil {
			return err
		}
	}
	return nil
}
