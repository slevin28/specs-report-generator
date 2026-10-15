package main

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestCollectorBesideExecutableRegardlessOfWorkingDirectory(t *testing.T) {
	usb := filepath.Join(t.TempDir(), "USB with spaces ' $ and %")
	if err := os.MkdirAll(usb, 0755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(usb, "ubuntu-specs.sh")
	if err := os.WriteFile(script, []byte("#!/bin/bash\n"), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := collectorPath(filepath.Join(usb, "Ubuntu Specs.exe"))
	if err != nil || got != script {
		t.Fatalf("got %q, %v; want %q", got, err, script)
	}
}

func TestMissingOrDirectoryCollectorRejected(t *testing.T) {
	usb := t.TempDir()
	executable := filepath.Join(usb, "Ubuntu Specs.exe")
	if _, err := collectorPath(executable); err == nil {
		t.Fatal("missing collector accepted")
	}
	if err := os.Mkdir(filepath.Join(usb, "ubuntu-specs.sh"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := collectorPath(executable); err == nil {
		t.Fatal("directory accepted")
	}
}

func TestTerminalArgumentTransportAndFallbacks(t *testing.T) {
	script := "/media/ubuntu/USB ' $() %/ubuntu-specs.sh"
	for _, item := range []struct {
		terminal string
		prefix   []string
	}{
		{"gnome-terminal", []string{"--wait", "--"}},
		{"ptyxis", []string{"--"}},
		{"kgx", []string{"--"}},
		{"x-terminal-emulator", []string{"-e"}},
	} {
		t.Run(item.terminal, func(t *testing.T) {
			lookup := func(name string) (string, error) {
				if name == item.terminal {
					return "/usr/bin/" + name, nil
				}
				return "", errors.New("missing")
			}
			cmd, err := terminalCommand(script, []string{"--no-sudo", "--output-dir", "/media/a b/Reports"}, lookup)
			if err != nil {
				t.Fatal(err)
			}
			want := append([]string{"/usr/bin/" + item.terminal}, item.prefix...)
			want = append(want, "/usr/bin/bash", script, "--wait", "--no-sudo", "--output-dir", "/media/a b/Reports")
			if !reflect.DeepEqual(cmd.Args, want) {
				t.Fatalf("got %#v; want %#v", cmd.Args, want)
			}
			if cmd.Dir != filepath.Dir(script) {
				t.Fatalf("wrong directory: %s", cmd.Dir)
			}
		})
	}
}

func TestMissingTerminalReported(t *testing.T) {
	_, err := terminalCommand("/usb/ubuntu-specs.sh", nil, func(string) (string, error) { return "", errors.New("missing") })
	if err == nil {
		t.Fatal("expected a useful error")
	}
}

func TestTerminalReceivesSingleLiteralScriptArgument(t *testing.T) {
	// Exercise real process argument transport, rather than shell-quoting a path.
	dir := t.TempDir()
	terminal := filepath.Join(dir, "mock terminal")
	output := filepath.Join(dir, "arguments")
	t.Setenv("UBUNTU_LAUNCHER_TEST_OUTPUT", output)
	if err := os.WriteFile(terminal, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$UBUNTU_LAUNCHER_TEST_OUTPUT\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	script := "/media/USB ' $() %/ubuntu-specs.sh"
	cmd, err := terminalCommand(script, []string{"--no-sudo"}, func(string) (string, error) { return terminal, nil })
	if err != nil {
		t.Fatal(err)
	}
	cmd.Dir = dir
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := "--wait\n--\n/usr/bin/bash\n" + script + "\n--wait\n--no-sudo\n"
	if string(got) != want {
		t.Fatalf("got %q; want %q", got, want)
	}
}
