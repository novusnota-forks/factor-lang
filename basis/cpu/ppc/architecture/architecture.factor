! Copyright (C) 2005, 2008 Slava Pestov.
! See http://factorcode.org/license.txt for BSD license.
USING: accessors alien.c-types cpu.ppc.assembler
cpu.architecture generic kernel kernel.private math memory
namespaces sequences words assocs compiler.generator
compiler.generator.registers compiler.generator.fixup system
layouts classes words.private alien combinators
compiler.constants math.order make ;
IN: cpu.ppc.architecture

! PowerPC register assignments
! r3-r10, r16-r31: integer vregs
! f0-f13: float vregs
! r11, r12: scratch
! r14: data stack
! r15: retain stack

: ds-reg 14 ; inline
: rs-reg 15 ; inline

: reserved-area-size ( -- n )
    os {
        { linux [ 2 ] }
        { macosx [ 6 ] }
    } case cells ; foldable

: lr-save ( -- n )
    os {
        { linux [ 1 ] }
        { macosx [ 2 ] }
    } case cells ; foldable

: param@ ( n -- x ) reserved-area-size + ; inline

: param-save-size ( -- n ) 8 cells ; foldable

: local@ ( n -- x )
    reserved-area-size param-save-size + + ; inline

: factor-area-size ( -- n ) 2 cells ; foldable

: next-save ( n -- i ) cell - ;

: xt-save ( n -- i ) 2 cells - ;

M: ppc stack-frame-size ( n -- i )
    local@ factor-area-size + 4 cells align ;

M: temp-reg v>operand drop 11 ;

M: int-regs return-reg drop 3 ;
M: int-regs param-regs drop { 3 4 5 6 7 8 9 10 } ;
M: int-regs vregs
    drop {
        3 4 5 6 7 8 9 10
        16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
    } ;

M: float-regs return-reg drop 1 ;
M: float-regs param-regs 
    drop os H{
        { macosx { 1 2 3 4 5 6 7 8 9 10 11 12 13 } }
        { linux { 1 2 3 4 5 6 7 8 } }
    } at ;
M: float-regs vregs drop { 0 1 2 3 4 5 6 7 8 9 10 11 12 13 } ;

GENERIC: loc>operand ( loc -- reg n )

M: ds-loc loc>operand n>> cells neg ds-reg swap ;
M: rs-loc loc>operand n>> cells neg rs-reg swap ;

M: immediate load-literal
    [ v>operand ] bi@ LOAD ;

M: ppc load-indirect ( obj reg -- )
    [ 0 swap LOAD32 rc-absolute-ppc-2/2 rel-literal ] keep
    dup 0 LWZ ;

M: ppc %save-word-xt ( -- )
    0 11 LOAD32 rc-absolute-ppc-2/2 rel-this ;

M: ppc %prologue ( n -- )
    0 MFLR
    1 1 pick neg ADDI
    11 1 pick xt-save STW
    dup 11 LI
    11 1 pick next-save STW
    0 1 rot lr-save + STW ;

M: ppc %epilogue ( n -- )
    #! At the end of each word that calls a subroutine, we store
    #! the previous link register value in r0 by popping it off
    #! the stack, set the link register to the contents of r0,
    #! and jump to the link register.
    0 1 pick lr-save + LWZ
    1 1 rot ADDI
    0 MTLR ;

: (%call) ( reg -- ) MTLR BLRL ;

: (%jump) ( reg -- ) MTCTR BCTR ;

: %load-dlsym ( symbol dll register -- )
    0 swap LOAD32 rc-absolute-ppc-2/2 rel-dlsym ;

M: ppc %call ( label -- ) BL ;

M: ppc %jump-label ( label -- ) B ;

M: ppc %jump-f ( label -- )
    0 "flag" operand f v>operand CMPI BEQ ;

M: ppc %dispatch ( -- )
    [
        %epilogue-later
        0 11 LOAD32 rc-absolute-ppc-2/2 rel-here
        "offset" operand "n" operand 1 SRAWI
        11 11 "offset" operand ADD
        11 dup 6 cells LWZ
        11 (%jump)
    ] H{
        { +input+ { { f "n" } } }
        { +scratch+ { { f "offset" } } }
    } with-template ;

M: ppc %dispatch-label ( word -- )
    0 , rc-absolute-cell rel-word ;

M: ppc %return ( -- ) %epilogue-later BLR ;

M: ppc %unwind drop %return ;

M: ppc %peek ( vreg loc -- )
    >r v>operand r> loc>operand LWZ ;

M: ppc %replace
    >r v>operand r> loc>operand STW ;

M: ppc %unbox-float ( dst src -- )
    [ v>operand ] bi@ float-offset LFD ;

M: ppc %inc-d ( n -- ) ds-reg dup rot cells ADDI ;

M: ppc %inc-r ( n -- ) rs-reg dup rot cells ADDI ;

M: int-regs %save-param-reg drop 1 rot local@ STW ;

M: int-regs %load-param-reg drop 1 rot local@ LWZ ;

GENERIC: STF ( src dst off reg-class -- )

M: single-float-regs STF drop STFS ;

M: double-float-regs STF drop STFD ;

M: float-regs %save-param-reg >r 1 rot local@ r> STF ;

GENERIC: LF ( dst src off reg-class -- )

M: single-float-regs LF drop LFS ;

M: double-float-regs LF drop LFD ;

M: float-regs %load-param-reg >r 1 rot local@ r> LF ;

M: stack-params %load-param-reg ( stack reg reg-class -- )
    drop >r 0 1 rot local@ LWZ 0 1 r> param@ STW ;

: next-param@ ( n -- x ) param@ stack-frame get total-size>> + ;

M: stack-params %save-param-reg ( stack reg reg-class -- )
    #! Funky. Read the parameter from the caller's stack frame.
    #! This word is used in callbacks
    drop
    0 1 rot next-param@ LWZ
    0 1 rot local@ STW ;

M: ppc %prepare-unbox ( -- )
    ! First parameter is top of stack
    3 ds-reg 0 LWZ
    ds-reg dup cell SUBI ;

M: ppc %unbox ( n reg-class func -- )
    ! Value must be in r3
    ! Call the unboxer
    f %alien-invoke
    ! Store the return value on the C stack
    over [ [ return-reg ] keep %save-param-reg ] [ 2drop ] if ;

M: ppc %unbox-long-long ( n func -- )
    ! Value must be in r3:r4
    ! Call the unboxer
    f %alien-invoke
    ! Store the return value on the C stack
    [
        3 1 pick local@ STW
        4 1 rot cell + local@ STW
    ] when* ;

M: ppc %unbox-large-struct ( n c-type -- )
    ! Value must be in r3
    ! Compute destination address and load struct size
    [ 4 1 rot local@ ADDI ] [ heap-size 5 LI ] bi*
    ! Call the function
    "to_value_struct" f %alien-invoke ;

M: ppc %box ( n reg-class func -- )
    ! If the source is a stack location, load it into freg #0.
    ! If the source is f, then we assume the value is already in
    ! freg #0.
    >r
    over [ 0 over param-reg swap %load-param-reg ] [ 2drop ] if
    r> f %alien-invoke ;

M: ppc %box-long-long ( n func -- )
    >r [
        3 1 pick local@ LWZ
        4 1 rot cell + local@ LWZ
    ] when* r> f %alien-invoke ;

: struct-return@ ( n -- n )
    [ stack-frame get params>> ] unless* local@ ;

M: ppc %prepare-box-struct ( -- )
    #! Compute target address for value struct return
    3 1 f struct-return@ ADDI
    3 1 0 local@ STW ;

M: ppc %box-large-struct ( n c-type -- )
    ! If n = f, then we're boxing a returned struct
    ! Compute destination address and load struct size
    [ 3 1 rot struct-return@ ADDI ] [ heap-size 4 LI ] bi*
    ! Call the function
    "box_value_struct" f %alien-invoke ;

M: ppc %prepare-alien-invoke
    #! Save Factor stack pointers in case the C code calls a
    #! callback which does a GC, which must reliably trace
    #! all roots.
    "stack_chain" f 11 %load-dlsym
    11 11 0 LWZ
    1 11 0 STW
    ds-reg 11 8 STW
    rs-reg 11 12 STW ;

M: ppc %alien-invoke ( symbol dll -- )
    11 %load-dlsym 11 (%call) ;

M: ppc %alien-callback ( quot -- )
    3 load-indirect "c_to_factor" f %alien-invoke ;

M: ppc %prepare-alien-indirect ( -- )
    "unbox_alien" f %alien-invoke
    13 3 MR ;

M: ppc %alien-indirect ( -- )
    13 (%call) ;

M: ppc %callback-value ( ctype -- )
     ! Save top of data stack
     3 ds-reg 0 LWZ
     3 1 0 local@ STW
     ! Restore data/call/retain stacks
     "unnest_stacks" f %alien-invoke
     ! Restore top of data stack
     3 1 0 local@ LWZ
     ! Unbox former top of data stack to return registers
     unbox-return ;

M: ppc %cleanup ( alien-node -- ) drop ;

: %untag ( src dest -- ) 0 0 31 tag-bits get - RLWINM ;

: %tag-fixnum ( src dest -- ) tag-bits get SLWI ;

: %untag-fixnum ( dest src -- ) tag-bits get SRAWI ;

M: ppc value-structs?
    #! On Linux/PPC, value structs are passed in the same way
    #! as reference structs, we just have to make a copy first.
    os linux? not ;

M: ppc fp-shadows-int? ( -- ? ) os macosx? ;

M: ppc small-enough? ( n -- ? ) -32768 32767 between? ;

M: ppc struct-small-enough? ( size -- ? ) drop f ;

M: ppc %box-small-struct
    drop "No small structs" throw ;

M: ppc %unbox-small-struct
    drop "No small structs" throw ;

! Alien intrinsics
M: ppc %unbox-byte-array ( dst src -- )
    [ v>operand ] bi@ byte-array-offset ADDI ;

M: ppc %unbox-alien ( dst src -- )
    [ v>operand ] bi@ alien-offset LWZ ;

M: ppc %unbox-f ( dst src -- )
    drop 0 swap v>operand LI ;

M: ppc %unbox-any-c-ptr ( dst src -- )
    { "is-byte-array" "end" "start" } [ define-label ] each
    ! Address is computed in R12
    0 12 LI
    ! Load object into R11
    11 swap v>operand MR
    ! We come back here with displaced aliens
    "start" resolve-label
    ! Is the object f?
    0 11 f v>operand CMPI
    ! If so, done
    "end" get BEQ
    ! Is the object an alien?
    0 11 header-offset LWZ
    0 0 alien type-number tag-fixnum CMPI
    "is-byte-array" get BNE
    ! If so, load the offset
    0 11 alien-offset LWZ
    ! Add it to address being computed
    12 12 0 ADD
    ! Now recurse on the underlying alien
    11 11 underlying-alien-offset LWZ
    "start" get B
    "is-byte-array" resolve-label
    ! Add byte array address to address being computed
    12 12 11 ADD
    ! Add an offset to start of byte array's data area
    12 12 byte-array-offset ADDI
    "end" resolve-label
    ! Done, store address in destination register
    v>operand 12 MR ;
