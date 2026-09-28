# there

`cd` there simply.

```sh
t ~/src/gopherql               # save it and go there
t gopherql                     # go there again
t +go +cli ~/src/minigontainer # save it with tags
t +go                          # pick from everything tagged +go
```

One match goes straight there. Two or more open the picker. No match is an error,
not a guess.

## Install

Needs `lua` 5.2+, `jq` 1.6+, and `fzf` for the picker. Bash, zsh or fish.

```sh
curl -sL https://codeberg.org/initsyscall/there/raw/branch/main/install.lua | lua -
```

It reports what it found, shows what it will write, and asks first.

```sh
curl -sL https://codeberg.org/initsyscall/there/raw/branch/main/install.lua | lua - --dry-run
```

Same report, nothing written, no prompt. One dash works too, so `-n` and
`-dry-run` are the same thing.

Then open a new shell.

## Uninstall

```sh
lua install.lua --uninstall
```

Removes the script and your shell config, then asks about the store. Answer `n`
and your bookmarks stay.

## How it works

A program cannot change the directory of the shell that started it. So `t` prints
one line of shell code and a small function `eval`s it:

```sh
cd '/home/you/src/gopherql'
```

That line is the whole interface. Everything else exists to produce it safely.

## Commands

```text
t <name>            jump to a saved path
t <path>            save a path, then jump to it
t +a +b <path>      save a path with tags
t +a +b             pick from everything carrying those tags
t list              pick from everything saved
t untagged          pick from the paths with no tag
t add <glob>        save every directory a glob names
t rm <name|glob>    remove a saved path
t rt <tag>          drop a tag, keep the paths
t rta <tag>         remove every path carrying a tag
t init <shell>      print the shell wrapper
```

A name matches the last segment of a path or any trailing part, so `t gopherql`
and `t moon/themeInitNvim` both work. Anything with a `/`, or starting with `~`
or `.`, is a path and gets saved.

Tags start with `+` and need no quoting. Not `#`, because that begins a comment
in every shell — the tag would vanish before `t` saw it.

## The store

`~/.there.json`, mode 600. Safe to edit by hand.

```json
{
  "paths": [
    { "path": "/home/you/src/gopherql", "tags": ["+work", "+cli"] },
    { "path": "/home/you/src/climer", "tags": [] }
  ]
}
```

A path is written once however many tags it carries. Deleted directories are
dropped for you, with a note when it happens.

## Notes

- A glob with a space in it does not work. Single paths with spaces are fine.
- A bookmark named after a subcommand (`list`) needs `t /path/to/list`.
- `sh`, `dash` and Windows are not supported.
- Without a terminal the picker prints candidates instead.

Apache 2.0. See [LICENSE](LICENSE).
