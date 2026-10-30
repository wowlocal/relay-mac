#!/usr/bin/env python3
"""Links local Swift packages to the Telegram app target in Telegram.xcodeproj, the way the existing ones are linked
(a folder reference in the Packages group, a package product dependency of the target, the product in its Frameworks
phase). Uses GroupsInCommonUI's entries to find the group, the target and the phase.

    tools/relay-add-package.py <path relative to the repository> <product> [<path> <product> ...]
"""
import hashlib
import re
import sys

PROJECT = "Telegram.xcodeproj/project.pbxproj"
ANCHOR = "GroupsInCommonUI"


def new_id(seed):
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def block_containing(text, position, opener):
    start = text.rfind(opener, 0, position)
    if start < 0:
        raise SystemExit("no %r before %d" % (opener, position))
    return start


def main(args):
    if not args or len(args) % 2:
        raise SystemExit(__doc__)
    text = open(PROJECT).read()
    anchor_file = re.search(r"(\w{24}) /\* %s \*/ = \{isa = PBXFileReference;" % ANCHOR, text).group(1)
    anchor_build = re.search(r"(\w{24}) /\* %s in Frameworks \*/ = \{isa = PBXBuildFile;" % ANCHOR, text).group(1)
    anchor_product = re.search(r"(\w{24}) /\* %s \*/ = \{\s*isa = XCSwiftPackageProductDependency;" % ANCHOR, text).group(1)

    for path, product in zip(args[0::2], args[1::2]):
        if re.search(r"productName = %s;" % re.escape(product), text):
            print("%s: already linked" % product)
            continue
        file_id, build_id, product_id = new_id("file:" + path), new_id("build:" + product), new_id("product:" + product)
        name = path.rstrip("/").split("/")[-1]
        quoted_path = '"%s"' % path if "-" in path or " " in path else path

        line = "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = folder; name = %s; path = %s; sourceTree = \"<group>\"; };\n" % (file_id, name, name, quoted_path)
        anchor_line = text.index("\t\t%s /* %s */ = {isa = PBXFileReference;" % (anchor_file, ANCHOR))
        text = text[:anchor_line] + line + text[anchor_line:]

        line = "\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; productRef = %s /* %s */; };\n" % (build_id, product, product_id, product)
        anchor_line = text.index("\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile;" % (anchor_build, ANCHOR))
        text = text[:anchor_line] + line + text[anchor_line:]

        # Group child, Frameworks phase entry and the target's package product dependency, each next to the anchor's.
        for anchor, entry in [
            ("\t\t\t\t%s /* %s */,\n" % (anchor_file, ANCHOR), "\t\t\t\t%s /* %s */,\n" % (file_id, name)),
            ("\t\t\t\t%s /* %s in Frameworks */,\n" % (anchor_build, ANCHOR), "\t\t\t\t%s /* %s in Frameworks */,\n" % (build_id, product)),
            ("\t\t\t\t%s /* %s */,\n" % (anchor_product, ANCHOR), "\t\t\t\t%s /* %s */,\n" % (product_id, product)),
        ]:
            if text.count(anchor) != 1:
                raise SystemExit("anchor %r found %d times" % (anchor.strip(), text.count(anchor)))
            text = text.replace(anchor, entry + anchor)

        block = "\t\t%s /* %s */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = %s;\n\t\t};\n" % (product_id, product, product)
        anchor_line = text.index("\t\t%s /* %s */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;" % (anchor_product, ANCHOR))
        text = text[:anchor_line] + block + text[anchor_line:]
        print("%s: linked (%s)" % (product, path))
    open(PROJECT, "w").write(text)


main(sys.argv[1:])
