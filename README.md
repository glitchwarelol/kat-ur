# Katana User Repository package template

1. Copy this directory to `packages/<package-name>/`.
2. Rename `my-app.recipe` to `<package-name>.recipe`.
3. Set the metadata fields and source URL at the top of the recipe.
4. Put build steps in `build()` and install files beneath `$pkgdir` in
   `package()`. The build system clones the source before calling `build()`.
5. Test locally with `./build.sh`; it creates a `.kat` archive containing the
   package files and generated `metadata.json`.
6. Submit the same metadata and function bodies through the website. The Worker
   writes the recipe to R2, and the scheduled workflow builds it.

The builder uses Bash, Git, GNU tar, and `jq`. Recipes execute as untrusted code
in a separate workflow job that receives no R2 or release credentials.
