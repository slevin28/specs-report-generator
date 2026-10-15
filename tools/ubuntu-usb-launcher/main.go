// Ubuntu USB entry point. Build as a native Linux executable with CGO disabled.
// The .exe suffix permits execution on Ubuntu's default FAT "showexec" mounts;
// the contents are Linux ELF, with no Wine or Windows runtime dependency.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func reportError(err error) {
	message := "Ubuntu Specs could not start.\n\n" + err.Error() +
		"\n\nKeep Ubuntu Specs.exe and ubuntu-specs.sh together on the USB.\n" +
		"Fallback: open the USB folder in Terminal and run: bash ubuntu-specs.sh"
	fmt.Fprintln(os.Stderr, message)
	// Ubuntu Desktop includes GTK through system Python. Use it only for an
	// error dialog when no terminal is available; the collector needs no GUI kit.
	python, lookupErr := exec.LookPath("python3")
	if lookupErr == nil {
		dialog := `import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
d = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE, text='Ubuntu Specs')
d.format_secondary_text(sys.argv[1])
d.run()
d.destroy()`
		cmd := exec.Command(python, "-I", "-c", dialog, message)
		_ = cmd.Run()
	}
}

func collectorPath(executable string) (string, error) {
	// Resolve our own location rather than assuming the file manager's working
	// directory or a fixed USB name, mount path, username, or serial number.
	script := filepath.Join(filepath.Dir(executable), "ubuntu-specs.sh")
	info, err := os.Stat(script)
	if err != nil {
		return "", fmt.Errorf("reporter unavailable: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("reporter is not a regular file: %s", script)
	}
	return script, nil
}

func terminalCommand(script string, args []string, lookPath func(string) (string, error)) (*exec.Cmd, error) {
	// Pass arguments directly; never interpret filenames or arguments as shell
	// code. Bash reads the companion script even if FAT gives it no execute bit.
	for _, terminal := range []struct {
		name   string
		prefix []string
	}{
		{"gnome-terminal", []string{"--wait", "--"}},
		{"ptyxis", []string{"--"}},
		{"kgx", []string{"--"}},
		{"x-terminal-emulator", []string{"-e"}},
	} {
		path, err := lookPath(terminal.name)
		if err != nil {
			continue
		}
		argv := append([]string{}, terminal.prefix...)
		argv = append(argv, "/usr/bin/bash", script, "--wait")
		argv = append(argv, args...)
		cmd := exec.Command(path, argv...)
		cmd.Dir = filepath.Dir(script)
		return cmd, nil
	}
	return nil, fmt.Errorf("no supported terminal found (GNOME Terminal, Ptyxis, Console, or x-terminal-emulator)")
}

func run() int {
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("Ubuntu Specs USB launcher (native Linux).\nKeep this file beside ubuntu-specs.sh. Double-click it to generate a report.\nAdditional options are passed to ubuntu-specs.sh. Requires a USB mount that allows execution.")
		return 0
	}
	executable, err := os.Executable()
	if err != nil {
		reportError(err)
		return 1
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		reportError(err)
		return 1
	}
	script, err := collectorPath(executable)
	if err != nil {
		reportError(err)
		return 1
	}
	cmd, err := terminalCommand(script, os.Args[1:], exec.LookPath)
	if err != nil {
		reportError(err)
		return 1
	}
	// Preserve the user's desktop environment/D-Bus session. The reporter asks
	// for sudo only inside the terminal, never as a root GUI process.
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			// The reporter's terminal already displayed the error and pause.
			return exit.ExitCode()
		}
		reportError(fmt.Errorf("could not open %s: %w", strings.TrimSpace(cmd.Path), err))
		return 1
	}
	return 0
}

func main() { os.Exit(run()) }
