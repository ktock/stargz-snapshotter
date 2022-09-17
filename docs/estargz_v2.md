# eStargz v2 specs (experimental)

This document lists unstable specs discussed towards eStargz v2.

Note that they are still experimental and subject to change.
And old stargz-snapshotter doesn't understand these spec and lazy pulling might fail or result in unexpected behaviours.

:information_source: For eStargz v1 syntaxes, refer to [`./estargz.md`](./estargz.md)

## `innerOffset`

- **`innerOffset`** *int64*

  This OPTIONAL property indicates the uncompressed offset of the "reg" or "chunk" entry payload in a stream starts from `offset` field. 

`innerOffset` enables to put multiple "reg" or "chunk" payloads in one gzip stream starts from `offset`.
This field allows the following structure.

![The structure of eStargz with innerOffset](/docs/images/estargz-inneroffset.png)

Use case of this field is `--estargz-min-chunk-size` flag of `ctr-remote`.
This is the minimal number of bytes of data must be written in one gzip stream. 
If it's > 0, multiple files and chunks can be written into one gzip stream. 
Smaller number of gzip header and smaller size of the result blob can be expected.
