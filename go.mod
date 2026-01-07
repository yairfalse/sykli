module sykli-ci

go 1.21

require sykli.dev/go v0.1.2

require (
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.19 // indirect
	github.com/rs/zerolog v1.34.0 // indirect
	golang.org/x/sys v0.12.0 // indirect
)

replace sykli.dev/go => ./sdk/go
