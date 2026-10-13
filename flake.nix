{
  description = "Zig URL image resize service with libvips";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = f: builtins.listToAttrs (map (s: { name = s; value = f s; }) systems);
    in
    {
      devShells = forEachSystem (system:
        let pkgs = import nixpkgs { inherit system; }; in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig
              vips
              pkg-config
              curl
              hyperfine
              gdb
            ];
            shellHook = ''
              echo "imgresize dev shell: $(pkg-config --modversion vips 2>/dev/null || echo 'vips ?')"
              echo "build: zig build -Doptimize=ReleaseFast  | run: ./zig-out/bin/imgresize"
            '';
          };
        });
    };
}
