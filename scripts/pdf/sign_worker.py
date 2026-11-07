#!/usr/bin/env python3
"""Digital signatures for the PDF helper, run with the python of its own
place (~/.local/share/pshell/pdf-venv, where pyHanko is installed by the
helper's `sigsetup`).

    sign_worker.py check
    sign_worker.py sign --in a.pdf --out b.pdf --cert c.p12 --password … --page n
                        --rect x0 y0 x1 y1 [--reason …] [--location …] [--field …] [--pdf-password …]

The rectangle is in PDF user space of the page; the signature is a new
field there, its appearance pyHanko's stamp (who, when, why).
"""
import argparse
import sys


def check():
    import pyhanko  # noqa: F401
    from pyhanko.sign import signers  # noqa: F401
    print("ok")
    return 0


def sign(args):
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers
    signer = signers.SimpleSigner.load_pkcs12(pfx_file=args.cert, passphrase=args.password.encode() if args.password else None)
    if signer is None:
        print("The certificate could not be opened (wrong password?)", file=sys.stderr)
        return 1
    with open(args.input, "rb") as source:
        writer = IncrementalPdfFileWriter(source)
        if args.pdf_password:
            writer.encrypt(args.pdf_password)
        name = args.field or "Signature"
        box = tuple(int(round(float(v))) for v in args.rect)
        fields.append_signature_field(writer, sig_field_spec=fields.SigFieldSpec(sig_field_name=name, on_page=args.page, box=box))
        meta = signers.PdfSignatureMetadata(field_name=name, reason=args.reason or None, location=args.location or None)
        with open(args.output, "wb") as out:
            signers.sign_pdf(writer, meta, signer=signer, output=out)
    return 0


def main(argv):
    if argv and argv[0] == "check":
        return check()
    parser = argparse.ArgumentParser()
    parser.add_argument("what")
    parser.add_argument("--in", dest="input", required=True)
    parser.add_argument("--out", dest="output", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--password", default="")
    parser.add_argument("--pdf-password", default="")
    parser.add_argument("--reason", default="")
    parser.add_argument("--location", default="")
    parser.add_argument("--field", default="Signature")
    parser.add_argument("--page", type=int, default=0)
    parser.add_argument("--rect", nargs=4, required=True)
    args = parser.parse_args(argv)
    if args.what != "sign":
        parser.error("sign or check")
    return sign(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
