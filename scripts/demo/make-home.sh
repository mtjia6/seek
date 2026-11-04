#!/bin/zsh
# Builds a fake home folder of sample files, used for README screenshots so
# no real personal files ever appear in them.
#   scripts/demo/make-home.sh [out-dir]      (default: build/demo-home)
set -euo pipefail
cd "$(dirname "$0")"
H=${1:-../../build/demo-home}
T=text
BIN=../../build/mkdemo

mkdir -p ../../build
swiftc -O mkdemo.swift -o $BIN
rm -rf $H
mkdir -p $H/{Desktop,Downloads,Documents/{Housing,Awards,"School/CS 3210/hw"},Dev/{raytracer/{src,scenes},notes}}

$BIN pdf "$H/Documents/Housing/Residential Lease Agreement - 14 Maple St.pdf" $T/lease.txt
$BIN pdf "$H/Downloads/parking_addendum_signed.pdf" $T/addendum.txt
$BIN pdf "$H/Downloads/boarding_pass_ATL_SFO.pdf" $T/bp.txt
$BIN pdf "$H/Documents/Awards/Physics Distinction Award.pdf" $T/award.txt
$BIN pdf "$H/Documents/School/CS 3210/CS3210 Syllabus Fall 2026.pdf" $T/syllabus.txt
$BIN png "$H/Desktop/Screenshot 2026-10-31 at 6.41.39 PM.png" $T/ocr.txt
$BIN png "$H/Desktop/Screenshot 2026-11-02 at 9.12.04 AM.png" $T/ocr2.txt
textutil -convert docx -output "$H/Documents/School/CS 3210/L07 Memory management.docx" $T/vm.html
textutil -convert docx -output "$H/Documents/School/CS 3210/L05 CPU scheduling.docx" $T/sched.html

cat > "$H/Dev/raytracer/src/bvh.rs" <<'EOF'
use crate::aabb::Aabb;
use crate::ray::Ray;

/// A bounding volume hierarchy: a binary tree of boxes, so a ray tests
/// O(log n) objects instead of all of them.
pub struct Bvh {
    nodes: Vec<Node>,
}
EOF
printf '# raytracer\n\nA small path tracer in Rust with a BVH and importance sampling.\n' > "$H/Dev/raytracer/README.md"
printf 'fn main() {\n    println!("rendering 800x450");\n}\n' > "$H/Dev/raytracer/src/main.rs"
printf 'date,item,amount\n2026-10-01,rent,1150\n2026-10-03,groceries,64.20\n' > "$H/Documents/budget-2026.csv"
printf 'Notes from advisor meeting\n- pick electives for spring\n' > "$H/Documents/advisor notes.txt"
for n in 1 2 3 4 5 6; do printf "# HW$n\n\nProblem 1: explain the trade-offs of question $n.\n" > "$H/Documents/School/CS 3210/hw/hw$n.md"; done
for s in cornell spheres glass bunny dragon sponza; do printf 'camera 0 1 5\nlight 0 4 0\n' > $H/Dev/raytracer/scenes/$s.scene; done
for n in sampling bvh-notes perf-log todo ideas; do printf "notes on $n\n" > $H/Dev/notes/$n.md; done
for n in 1 2 3 4 5 6 7 8 9; do printf "journal entry $n\n" > $H/Documents/journal-$n.txt; done

# Spread modification times over two weeks so the activity chart has shape.
days=(0 0 0 1 1 1 1 2 2 3 4 4 5 6 6 6 6 6 7 8 9 9 10 11 12 13 2 1 0 3 5 7 1 0 2 4 6 8)
i=1
for f in ${(f)"$(find $H -type f)"}; do
  d=${days[$(( (i % ${#days}) + 1 ))]}
  touch -t $(date -v-${d}d -v-$((i % 9))H +%Y%m%d%H%M) "$f"
  i=$((i + 1))
done
touch "$H/Desktop/Screenshot 2026-10-31 at 6.41.39 PM.png"
echo "Demo home: $H ($(find $H -type f | wc -l | tr -d ' ') files)"
