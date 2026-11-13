import Quickshell.Io
// Process { command: ["sudo", "pacman", "-Syu"] } in this comment is not a call
Process {
  command: ["pkexec", "pacman", "-Rns", "fixture"]
}
