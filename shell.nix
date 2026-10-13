{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    vips
    pkg-config
    curl
    hyperfine
  ];
}
