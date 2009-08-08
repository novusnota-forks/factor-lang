! Copyright (C) 2008, 2009 Slava Pestov.
! See http://factorcode.org/license.txt for BSD license.
USING: kernel math vectors arrays accessors namespaces ;
IN: compiler.cfg

TUPLE: basic-block < identity-tuple
{ id integer }
number
{ instructions vector }
{ successors vector }
{ predecessors vector } ;

M: basic-block hashcode* nip id>> ;

: <basic-block> ( -- bb )
    basic-block new
        V{ } clone >>instructions
        V{ } clone >>successors
        V{ } clone >>predecessors
        \ basic-block counter >>id ;

TUPLE: cfg { entry basic-block } word label spill-area-size reps post-order ;

: <cfg> ( entry word label -- cfg )
    cfg new
        swap >>label
        swap >>word
        swap >>entry ;

: cfg-changed ( cfg -- cfg ) f >>post-order ; inline

TUPLE: mr { instructions array } word label ;

: <mr> ( instructions word label -- mr )
    mr new
        swap >>label
        swap >>word
        swap >>instructions ;
