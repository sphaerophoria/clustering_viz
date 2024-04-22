with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    gdb
    zlib
    valgrind
    # For linter script on push hook
    python3
    nodePackages.typescript-language-server
    vscode-langservers-extracted
    nodePackages.prettier
  ];
}

