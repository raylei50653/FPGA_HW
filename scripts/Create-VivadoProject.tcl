# Rebuild a homework project from version-controlled source files.
# Usage: vivado -mode batch -source scripts/Create-VivadoProject.tcl -tclargs HW1

set repo_root [file normalize [file join [file dirname [info script]] ..]]
if {![info exists homework]} {
    set homework [lindex $argv 0]
}
if {$homework eq ""} {
    set homework HW1
}
if {![regexp {^HW([1-9][0-9]*)(_[a-z]+)?$} $homework -> homework_number homework_suffix]} {
    error "Expected a homework name such as HW1 or HW2_a."
}

set homework_dir [file join $repo_root $homework]
set source_dir [file join $homework_dir src]
set simulation_dir [file join $homework_dir sim]
set constraints_dir [file join $homework_dir constraints]
set project_dir [file join $repo_root vivado $homework]
set project_file [file join $project_dir ${homework}.xpr]

if {![file isdirectory $source_dir]} {
    error "Missing source directory: $source_dir"
}
if {[file exists $project_file]} {
    error "Project already exists: $project_file. Open it instead of recreating it."
}

set source_files {}
foreach extension {vhd vhdl v sv} {
    foreach path [glob -nocomplain -directory $source_dir *.$extension] {
        lappend source_files $path
    }
}
if {[llength $source_files] == 0} {
    error "No design source found in $source_dir"
}

create_project $homework $project_dir -part xc7k70tfbv676-1
add_files -norecurse -fileset sources_1 $source_files
set_property top HW_${homework_number}${homework_suffix} [get_filesets sources_1]

set simulation_files {}
foreach extension {vhd vhdl v sv} {
    foreach path [glob -nocomplain -directory $simulation_dir *.$extension] {
        lappend simulation_files $path
    }
}
if {[llength $simulation_files] > 0} {
    add_files -norecurse -fileset sim_1 $simulation_files
    set_property top HW_${homework_number}${homework_suffix}_tb [get_filesets sim_1]
    if {[info exists sim_runtime]} {
        set_property -name {xsim.simulate.runtime} -value $sim_runtime -objects [get_filesets sim_1]
    }
}

set constraint_files [glob -nocomplain -directory $constraints_dir *.xdc]
if {[llength $constraint_files] > 0} {
    add_files -norecurse -fileset constrs_1 $constraint_files
}

update_compile_order -fileset sources_1
if {[llength $simulation_files] > 0} {
    update_compile_order -fileset sim_1
}
close_project
puts "Created $project_file"
