module InlineStrings

import Base: ==

using Parsers

export InlineString, InlineStringType, inlinestrings

"""
    InlineString

A set of custom string types of various fixed sizes. Each inline string
is a custom primitive type and can benefit from being stack friendly by
avoiding allocations/heap tracking in the GC. When used in an array,
the elements are able to be stored inline since each one has a fixed
size. Currently support inline strings from 1 byte up to 255 bytes.
See more details by looking at individual docs for [`String1`](@ref),
[`String3`](@ref), [`String7`](@ref), [`String15`](@ref), [`String31`](@ref),
[`String63`](@ref), [`String127`](@ref), or [`String255`](@ref).
"""
abstract type InlineString <: AbstractString end

for sz in (1, 4, 8, 16, 32, 64, 128, 256)
    nm = Symbol(:String, max(1, sz - 1))
    nma = Symbol(:InlineString, max(1, sz - 1))
    @eval begin
        """
            $($nm)(str::AbstractString)
            $($nm)(bytes::AbstractVector{UInt8}, pos, len)
            $($nm)(ptr::Ptr{UInt8}, [len])

        Custom fixed-size string with a fixed size of $($sz) bytes.
        1 byte is used to store the length of the string. If an
        inline string is shorter than $($(max(1, sz - 1))) bytes, the entire
        string still occupies the full $($sz) bytes since they are,
        by definition, fixed size. Otherwise, they can be treated
        just like normal `String` values. Note that `sizeof(x)` will
        return the # of _codeunits_ in an $($nm) like `String`, not
        the total fixed size. For the fixed size, call `sizeof($($nm))`.
        $($nm) can be constructed from an existing `String` (`$($nm)(x::AbstractString)`),
        from a byte buffer with position and length (`$($nm)(buf, pos, len)`),
        from a pointer with optional length (`$($nm)(ptr, len)`)
        or built iteratively by starting with `x = $($nm)()` and calling
        `x, overflowed = InlineStrings.addcodeunit(x, b::UInt8)` which returns a 
        new $($nm) with the new codeunit `b` appended and an `overflowed` `Bool`
        value indicating whether too many codeunits have been appended for the
        fixed size. When constructed from a pointer, note that the `ptr` must
        point to valid memory or program data may become corrupt. If the `len`
        argument is specified with the pointer, it must fit within the fixed size
        of $($nm); if no length is provided, the C-string is assumed to be
        NUL-terminated. If the NUL-terminated string ends up longer than can
        fit in $($nm), an ArgumentError will be thrown.
        """
        primitive type $nm <: InlineString $(sz * 8) end
        const $nma = $nm
        export $nm
        export $nma
    end
end

_bswap(x::T) where {T <: InlineString} = T === InlineString1 ? x : Base.bswap_int(x)

const InlineStringTypes = Union{InlineString1,
                            InlineString3,
                            InlineString7,
                            InlineString15,
                            InlineString31,
                            InlineString63,
                            InlineString127,
                            InlineString255}

function Base.promote_rule(::Type{T}, ::Type{S}) where {T <: InlineString, S <: InlineString}
    T === InlineString1 && return S
    S === InlineString1 && return T
    T === InlineString3 && return S
    S === InlineString3 && return T
    T === InlineString7 && return S
    S === InlineString7 && return T
    T === InlineString15 && return S
    S === InlineString15 && return T
    T === InlineString31 && return S
    S === InlineString31 && return T
    T === InlineString63 && return S
    S === InlineString63 && return T
    T === InlineString127 && return S
    S === InlineString127 && return T
    return InlineString255
end

Base.promote_rule(::Type{T}, ::Type{String}) where {T <: InlineString} = String

Base.widen(::Type{InlineString1}) = InlineString3
Base.widen(::Type{InlineString3}) = InlineString7
Base.widen(::Type{InlineString7}) = InlineString15
Base.widen(::Type{InlineString15}) = InlineString31
Base.widen(::Type{InlineString31}) = InlineString63
Base.widen(::Type{InlineString63}) = InlineString127
Base.widen(::Type{InlineString127}) = InlineString255
Base.widen(::Type{InlineString255}) = String

Base.ncodeunits(::InlineString1) = 1
Base.ncodeunits(x::InlineString) = Int(Base.trunc_int(UInt8, x))
Base.codeunit(::InlineString) = UInt8

Base.@propagate_inbounds function Base.codeunit(x::T, i::Int) where {T <: InlineString}
    @boundscheck checkbounds(Bool, x, i) || throw(BoundsError(x, i))
    if T === InlineString1
        return Base.bitcast(UInt8, x)
    else
        return Base.trunc_int(UInt8, Base.lshr_int(x, 8 * (sizeof(T) - i)))
    end
end

function Base.String(x::T) where {T <: InlineString}
    len = ncodeunits(x)
    out = Base._string_n(len)
    if T === InlineString1
        GC.@preserve out unsafe_store!(pointer(out), codeunit(x, 1))
        return out
    end
    ref = Ref{T}(_bswap(x))
    GC.@preserve ref out begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        unsafe_copyto!(pointer(out), ptr, len)
    end
    return out
end

function Base.Symbol(x::T) where {T <: InlineString}
    ref = Ref{T}(_bswap(x))
    return ccall(:jl_symbol_n, Ref{Symbol},
        (Ref{T}, Int), ref, sizeof(x))
end

# add a codeunit to end of string method
function addcodeunit(x::T, b::UInt8) where {T <: InlineString}
    if T === InlineString1
        return Base.bitcast(InlineString1, b), false
    end
    len = Base.trunc_int(UInt8, x)
    sz = Base.trunc_int(UInt8, sizeof(T))
    shf = Base.zext_int(Int16, max(0x01, sz - len - 0x01)) << 3
    x = Base.or_int(x, Base.shl_int(Base.zext_int(T, b), shf))
    return Base.add_int(x, Base.zext_int(T, 0x01)), (len + 0x01) >= sz
end

# from String
InlineString1(byte::UInt8=0x00) = Base.bitcast(InlineString1, byte)

function InlineString1(x::AbstractString)
    sizeof(x) == 1 || stringtoolong(InlineString1, sizeof(x))
    return Base.bitcast(InlineString1, codeunit(x, 1))    
end

function InlineString1(buf::AbstractVector{UInt8}, pos, len)
    len == 1 || stringtoolong(InlineString1, len)
    return Base.bitcast(InlineString1, buf[pos])
end

function InlineString1(ptr::Ptr{UInt8}, len=nothing)
    ptr == Ptr{UInt8}(0) && nullptr(InlineString1)
    if len === nothing
        y, _ = addcodeunit(InlineString1(), unsafe_load(ptr))
        unsafe_load(ptr, 2) === 0x00 || stringtoolong(InlineString1, 2)
        return y
    else
        len == 1 || stringtoolong(InlineString1, len)
        return Base.bitcast(InlineString1, unsafe_load(ptr))
    end
end

function InlineString1(x::S) where {S <: InlineString}
    sizeof(x) == 1 || stringtoolong(InlineString1, sizeof(x))
    return Base.bitcast(InlineString1, codeunit(x, 1))
end

for T in (:InlineString3, :InlineString7, :InlineString15, :InlineString31, :InlineString63, :InlineString127, :InlineString255)
    @eval $T() = Base.zext_int($T, 0x00)

    @eval function $T(x::AbstractString)
        if typeof(x) === String && sizeof($T) <= sizeof(UInt)
            len = sizeof(x)
            len < sizeof($T) || stringtoolong($T, len)
            y = GC.@preserve x unsafe_load(convert(Ptr{$T}, pointer(x)))
            sz = 8 * (sizeof($T) - len)
            return Base.or_int(Base.shl_int(Base.lshr_int(_bswap(y), sz), sz), Base.zext_int($T, UInt8(len)))
        else
            len = ncodeunits(x)
            len < sizeof($T) || stringtoolong($T, len)
            y = $T()
            for i = 1:len
                @inbounds y, _ = addcodeunit(y, codeunit(x, i))
            end
            return y
        end
    end

    @eval function $T(buf::AbstractVector{UInt8}, pos, len)
        blen = length(buf)
        blen < len && buftoosmall(len)
        len < sizeof($T) || stringtoolong($T, len)
        if (blen - pos + 1) < sizeof($T)
            # if our buffer isn't long enough to hold a full $T,
            # then we can't do our unsafe_load trick below because we'd be
            # unsafe_load-ing memory from beyond the end of buf
            # we need to build the InlineString byte-by-byte instead
            y = $T()
            for i = pos:(pos + len - 1)
                @inbounds y, _ = addcodeunit(y, buf[i])
            end
            return y
        else
            y = GC.@preserve buf unsafe_load(convert(Ptr{$T}, pointer(buf, pos)))
            sz = 8 * (sizeof($T) - len)
            return Base.or_int(Base.shl_int(Base.lshr_int(_bswap(y), sz), sz), Base.zext_int($T, UInt8(len)))
        end
    end

    @eval function $T(ptr::Ptr{UInt8}, len=nothing)
        ptr == Ptr{UInt8}(0) && nullptr($T)
        y = $T()
        if len === nothing
            i = 1
            while true
                b = unsafe_load(ptr, i)
                b == 0x00 && break
                @inbounds y, overflowed = addcodeunit(y, b)
                overflowed && stringtoolong($T, i)
                i += 1
            end
        else
            len < sizeof($T) || stringtoolong($T, len)
            for i = 1:len
                @inbounds y, _ = addcodeunit(y, unsafe_load(ptr, i))
            end
        end
        return y
    end

    # between InlineStringTypes
    @eval function $T(x::S) where {S <: InlineString}
        if $T === S
            return x
        elseif sizeof($T) < sizeof(S)
            # trying to compress
            len = sizeof(x)
            len > (sizeof($T) - 1) && stringtoolong($T, len)
            y = Base.trunc_int($T, Base.lshr_int(x, 8 * (sizeof(S) - sizeof($T))))
            return Base.add_int(y, Base.zext_int($T, UInt8(len)))
        else
            # promoting smaller InlineString to larger
            if S === InlineString1
                y = Base.shl_int(Base.zext_int($T, x), 8 * (sizeof($T) - sizeof(S)))
            else
                y = Base.shl_int(Base.zext_int($T, Base.lshr_int(x, 8)), 8 * (sizeof($T) - sizeof(S) + 1))
            end
            return Base.add_int(y, Base.zext_int($T, UInt8(sizeof(x))))
        end
    end
end

@noinline nullptr(T) = throw(ArgumentError("cannot convert NULL to $T"))
@noinline buftoosmall(n) = throw(ArgumentError("input buffer too short for requested length: $n"))
@noinline stringtoolong(T, n) = throw(ArgumentError("string too large ($n) to convert to $T"))

function InlineStringType(n::Integer)
    n > 255 && stringtoolong(InlineString, n)
    return n == 1  ? InlineString1   : n < 4  ? InlineString3  :
           n < 8   ? InlineString7   : n < 16 ? InlineString15 :
           n < 32  ? InlineString31  : n < 64 ? InlineString63 :
           n < 128 ? InlineString127 : InlineString255
end

InlineString(x::InlineString) = x
InlineString(x::AbstractString)::InlineStringTypes = (InlineStringType(ncodeunits(x)))(x)

(==)(x::T, y::T) where {T <: InlineString} = Base.eq_int(x, y)
function ==(x::String, y::T) where {T <: InlineString}
    sizeof(x) == sizeof(y) || return false
    ref = Ref{T}(_bswap(y))
    return ccall(:memcmp, Cint, (Ptr{UInt8}, Ref{T}, Csize_t),
            pointer(x), ref, sizeof(x)) == 0
end
==(y::InlineString, x::String) = x == y

Base.cmp(a::T, b::T) where {T <: InlineString} =
    Base.eq_int(a, b) ? 0 : Base.ult_int(a, b) ? -1 : 1

function Base.hash(x::T, h::UInt) where {T <: InlineString}
    h += Base.memhash_seed
    ref = Ref{T}(_bswap(x))
    return ccall(Base.memhash, UInt,
        (Ref{T}, Csize_t, UInt32),
        ref, sizeof(x), h % UInt32) + h
end

function Base.write(io::IO, x::T) where {T <: InlineString}
    ref = Ref{T}(x)
    return GC.@preserve ref begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        Int(unsafe_write(io, ptr, reinterpret(UInt, sizeof(T))))::Int
    end
end

function Base.read(s::IO, ::Type{T}) where {T <: InlineString}
    return read!(s, Ref{T}())[]::T
end

function Base.print(io::IO, x::T) where {T <: InlineString}
    x isa InlineString1 && return print(io, Char(Base.bitcast(UInt8, x)))
    ref = Ref{T}(_bswap(x))
    return GC.@preserve ref begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        unsafe_write(io, ptr, sizeof(x))
        return
    end
end

function Base.isascii(x::T) where {T <: InlineString}
    if T === InlineString1
        return codeunit(x, 1) < 0x80
    end
    len = ncodeunits(x)
    x = Base.lshr_int(x, 8 * (sizeof(T) - len))
    for _ = 1:(len >> 2)
        y = Base.trunc_int(UInt32, x)
        (y & 0xff000000) >= 0x80000000 && return false
        (y & 0x00ff0000) >= 0x00800000 && return false
        (y & 0x0000ff00) >= 0x00008000 && return false
        (y & 0x000000ff) >= 0x00000080 && return false
        x = Base.lshr_int(x, 32)
    end
    return true
end

# "mutating" operations; care must be taken here to "clear out"
# unused bits to ensure our == definition continues to work
# which compares the full bit contents of inline strings
Base.chop(s::InlineString1; kw...) = chop(String3(s); kw...)
function Base.chop(s::InlineString; head::Integer = 0, tail::Integer = 1)
    if isempty(s)
        return s
    end
    n = ncodeunits(s)
    i = min(n + 1, max(nextind(s, firstindex(s), head), 1))  # new firstindex
    j = max(0, min(n, prevind(s, lastindex(s), tail)))       # new lastindex
    jx = nextind(s, j) - 1                                   # last codeunit to keep
    new_n = max(0, nextind(s, j) - i)                        # new ncodeunits
    s = clear_n_bytes(s, sizeof(typeof(s)) - jx)
    return Base.or_int(Base.shl_int(s, (i - 1) * 8), _oftype(typeof(s), new_n))
end

if isdefined(Base, :chopprefix)

Base.chopprefix(s::InlineString1, prefix::AbstractString) = chopprefix(String3(s), prefix)
function Base.chopprefix(s::InlineString, prefix::AbstractString)
    if !isempty(prefix) && startswith(s, prefix)
        return _chopprefix(s, prefix)
    end
    return s
end

Base.chopprefix(s::InlineString1, prefix::Regex) = chopprefix(String3(s), prefix)
function Base.chopprefix(s::InlineString, prefix::Regex)
    m = match(prefix, String(s), firstindex(s), Base.PCRE.ANCHORED)
    m === nothing && return s
    isempty(m.match) && return s
    return _chopprefix(s, m.match)
end

@inline function _chopprefix(s::InlineString, prefix::AbstractString)
    n = ncodeunits(s)
    nprefix = ncodeunits(prefix)
    new_n = n - nprefix
    # `length` to call `nextind` for each "character" (not codeunit) in prefix
    i = min(n + 1, max(nextind(s, firstindex(s), length(prefix)), 1))
    s = clear_n_bytes(s, 1)           # clear out the length bits
    s = Base.shl_int(s, (i - 1) * 8)  # clear out prefix
    return Base.or_int(s, _oftype(typeof(s), new_n))
end

end # isdefined

if isdefined(Base, :chopsuffix)

Base.chopsuffix(s::InlineString1, suffix::AbstractString) = chopsuffix(String3(s), suffix)
function Base.chopsuffix(s::InlineString, suffix::AbstractString)
    if !isempty(suffix) && endswith(s, suffix)
        return _chopsuffix(s, suffix)
    end
    return s
end

Base.chopsuffix(s::InlineString1, suffix::Regex) = chopsuffix(String3(s), suffix)
function Base.chopsuffix(s::InlineString, suffix::Regex)
    m = match(suffix, String(s), firstindex(s), Base.PCRE.ENDANCHORED)
    m === nothing && return s
    isempty(m.match) && return s
    return _chopsuffix(s, m.match)
end

@inline function _chopsuffix(s::InlineString, suffix::AbstractString)
    n = ncodeunits(s)
    nsuffix = ncodeunits(suffix)
    new_n = n - nsuffix
    s = clear_n_bytes(s, sizeof(typeof(s)) - new_n)
    return Base.or_int(s, _oftype(typeof(s), new_n))
end

end # isdefined

# used to zero out n lower bytes of an inline string
clear_n_bytes(s, n) = Base.shl_int(Base.lshr_int(s, 8 * n), 8 * n)

Base.chomp(s::InlineString1) = chomp(String3(s))
function Base.chomp(s::InlineString)
    i = lastindex(s)
    len = ncodeunits(s)
    if i < 1 || codeunit(s, i) != 0x0a
        return s
    elseif i < 2 || codeunit(s, i - 1) != 0x0d
        return Base.or_int(clear_n_bytes(s, sizeof(typeof(s)) - i + 1), _oftype(typeof(s), len - 1))
    else
        return Base.or_int(clear_n_bytes(s, sizeof(typeof(s)) - i + 2), _oftype(typeof(s), len - 2))
    end
end

Base.first(s::InlineString1, n::Integer) = first(String3(s), n)
function Base.first(s::T, n::Integer) where {T <: InlineString}
    newlen = nextind(s, min(lastindex(s), nextind(s, 0, n))) - 1
    i = sizeof(T) - newlen
    return Base.or_int(clear_n_bytes(s, i), _oftype(typeof(s), newlen))
end

Base.last(s::InlineString1, n::Integer) = last(String3(s), n)
function Base.last(s::T, n::Integer) where {T <: InlineString}
    nc = ncodeunits(s) + 1
    i = max(1, prevind(s, nc, n))
    i == 1 && return s
    newlen = nc - i
    # clear out the length bits before shifting left
    s = clear_n_bytes(s, 1)
    return Base.or_int(Base.shl_int(s, (i - 1) * 8), _oftype(typeof(s), newlen))
end

Base.reverse(x::String1) = x
function Base.reverse(s::T) where {T <: InlineString}
    nc = ncodeunits(s)
    if isascii(s)
        len = Base.zext_int(T, Base.trunc_int(UInt8, s))
        x = Base.or_int(Base.shl_int(_bswap(s), 8 * (sizeof(T) - nc)), len)
        return x
    end
    x = Base.zext_int(T, Base.trunc_int(UInt8, s))
    i = 1
    while i <= nc
        j = nextind(s, i)
        _x = Base.lshr_int(s, 8 * (sizeof(T) - (j - 1)))
        n = j - i
        _x = Base.and_int(_x, n == 1 ? Base.zext_int(T, 0xff) :
            n == 2 ? Base.zext_int(T, 0xffff) :
            n == 3 ? Base.zext_int(T, 0xffffff) :
                     Base.zext_int(T, 0xffffffff))
        _x = Base.shl_int(_x, 8 * (sizeof(T) - (nc - (i - 1))))
        x = Base.or_int(x, _x)
        i = j
    end
    return x
end

@inline function Base.__unsafe_string!(out, x::T, offs::Integer) where {T <: InlineString}
    n = sizeof(x)
    ref = Ref{T}(_bswap(x))
    GC.@preserve ref out begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        unsafe_copyto!(pointer(out, offs), ptr, n)
    end
    return n
end

const BaseStrs = Union{Char, String, SubString{String}}
Base.string(a::InlineString) = String(a)
Base.string(a::InlineString...) = _string(a...)
Base.string(a::BaseStrs, b::InlineString) = _string(a, b)
Base.string(a::BaseStrs, b::BaseStrs, c::InlineString) = _string(a, b, c)
@inline function _string(a::Union{BaseStrs, InlineString}...)
    n = 0
    for v in a
        if v isa Char
            n += ncodeunits(v)
        else
            n += sizeof(v)
        end
    end
    out = Base._string_n(n)
    offs = 1
    for v in a
        offs += Base.__unsafe_string!(out, v, offs)
    end
    return out
end

function Base.repeat(x::T, r::Integer) where {T <: InlineString}
    r < 0 && throw(ArgumentError("can't repeat a string $r times"))
    r == 0 && return ""
    r == 1 && return s
    n = sizeof(x)
    out = Base._string_n(n * r)
    if n == 1 # common case: repeating a single-byte string
        @inbounds b = codeunit(x, 1)
        ccall(:memset, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Csize_t), out, b, r)
    else
        for i = 0:r-1
            ref = Ref{T}(_bswap(x))
            GC.@preserve ref out begin
                ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
                unsafe_copyto!(pointer(out, i * n + 1), ptr, n)
            end
        end
    end
    return out
end

# copy/pasted from strings/util.jl
function Base.startswith(a::T, b::Union{String, SubString{String}, InlineString}) where {T <: InlineString}
    cub = ncodeunits(b)
    ncodeunits(a) < cub && return false
    ref = Ref{T}(_bswap(a))
    return GC.@preserve ref begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        if Base._memcmp(ptr, b, sizeof(b)) == 0
            nextind(a, cub) == cub + 1
        else
            false
        end
    end
end

function Base.endswith(a::T, b::Union{String, SubString{String}, InlineString}) where {T <: InlineString}
    cub = ncodeunits(b)
    astart = ncodeunits(a) - ncodeunits(b) + 1
    astart < 1 && return false
    ref = Ref{T}(_bswap(a))
    return GC.@preserve ref begin
        ptr = convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, ref))
        if Base._memcmp(ptr + (astart - 1), b, sizeof(b)) == 0
            thisind(a, astart) == astart
        else
            false
        end
    end
end

Base.match(r::Regex, s::InlineString, i::Integer) = match(r, String(s), i)
Base.findnext(r::Regex, s::InlineString, i::Integer) = findnext(r, String(s), i)

# the rest of these methods are copy/pasted from Base strings/string.jl file
# for efficiency
Base.@propagate_inbounds function Base.isvalid(x::InlineString, i::Int)
    @boundscheck checkbounds(Bool, x, i) || throw(BoundsError(x, i))
    return @inbounds thisind(x, i) == i
end

Base.@propagate_inbounds function Base.thisind(s::InlineString, i::Int)
    i == 0 && return 0
    n = ncodeunits(s)
    i == n + 1 && return i
    @boundscheck Base.between(i, 1, n) || throw(BoundsError(s, i))
    @inbounds b = codeunit(s, i)
    (b & 0xc0 == 0x80) & (i-1 > 0) || return i
    @inbounds b = codeunit(s, i-1)
    Base.between(b, 0b11000000, 0b11110111) && return i-1
    (b & 0xc0 == 0x80) & (i-2 > 0) || return i
    @inbounds b = codeunit(s, i-2)
    Base.between(b, 0b11100000, 0b11110111) && return i-2
    (b & 0xc0 == 0x80) & (i-3 > 0) || return i
    @inbounds b = codeunit(s, i-3)
    Base.between(b, 0b11110000, 0b11110111) && return i-3
    return i
end

Base.@propagate_inbounds function Base.nextind(s::InlineString, i::Int)
    i == 0 && return 1
    n = ncodeunits(s)
    @boundscheck Base.between(i, 1, n) || throw(BoundsError(s, i))
    @inbounds l = codeunit(s, i)
    (l < 0x80) | (0xf8 ≤ l) && return i+1
    if l < 0xc0
        i′ = @inbounds thisind(s, i)
        return i′ < i ? @inbounds(nextind(s, i′)) : i+1
    end
    # first continuation byte
    (i += 1) > n && return i
    @inbounds b = codeunit(s, i)
    b & 0xc0 ≠ 0x80 && return i
    ((i += 1) > n) | (l < 0xe0) && return i
    # second continuation byte
    @inbounds b = codeunit(s, i)
    b & 0xc0 ≠ 0x80 && return i
    ((i += 1) > n) | (l < 0xf0) && return i
    # third continuation byte
    @inbounds b = codeunit(s, i)
    ifelse(b & 0xc0 ≠ 0x80, i, i+1)
end

Base.@propagate_inbounds function Base.iterate(s::InlineString, i::Int=firstindex(s))
    (i % UInt) - 1 < ncodeunits(s) || return nothing
    b = @inbounds codeunit(s, i)
    u = UInt32(b) << 24
    Base.between(b, 0x80, 0xf7) || return reinterpret(Char, u), i+1
    return iterate_continued(s, i, u)
end

function iterate_continued(s::InlineString, i::Int, u::UInt32)
    u < 0xc0000000 && (i += 1; @goto ret)
    n = ncodeunits(s)
    # first continuation byte
    (i += 1) > n && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 16
    # second continuation byte
    ((i += 1) > n) | (u < 0xe0000000) && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 8
    # third continuation byte
    ((i += 1) > n) | (u < 0xf0000000) && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b); i += 1
@label ret
    return reinterpret(Char, u), i
end

Base.@propagate_inbounds function Base.getindex(s::InlineString, i::Int)
    b = codeunit(s, i)
    u = UInt32(b) << 24
    Base.between(b, 0x80, 0xf7) || return reinterpret(Char, u)
    return getindex_continued(s, i, u)
end

function getindex_continued(s::InlineString, i::Int, u::UInt32)
    if u < 0xc0000000
        # called from `getindex` which checks bounds
        @inbounds isvalid(s, i) && @goto ret
        Base.string_index_err(s, i)
    end
    n = ncodeunits(s)

    (i += 1) > n && @goto ret
    @inbounds b = codeunit(s, i) # cont byte 1
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 16

    ((i += 1) > n) | (u < 0xe0000000) && @goto ret
    @inbounds b = codeunit(s, i) # cont byte 2
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 8

    ((i += 1) > n) | (u < 0xf0000000) && @goto ret
    @inbounds b = codeunit(s, i) # cont byte 3
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b)
@label ret
    return reinterpret(Char, u)
end

Base.length(s::InlineString) = length_continued(s, 1, ncodeunits(s), ncodeunits(s))

Base.@propagate_inbounds function Base.length(s::InlineString, i::Int, j::Int)
    @boundscheck begin
        0 < i ≤ ncodeunits(s)+1 || throw(BoundsError(s, i))
        0 ≤ j < ncodeunits(s)+1 || throw(BoundsError(s, j))
    end
    j < i && return 0
    @inbounds i, k = thisind(s, i), i
    c = j - i + (i == k)
    length_continued(s, i, j, c)
end

@inline function length_continued(s::InlineString, i::Int, n::Int, c::Int)
    i < n || return c
    @inbounds b = codeunit(s, i)
    @inbounds while true
        while true
            (i += 1) ≤ n || return c
            0xc0 ≤ b ≤ 0xf7 && break
            b = codeunit(s, i)
        end
        l = b
        b = codeunit(s, i) # cont byte 1
        c -= (x = b & 0xc0 == 0x80)
        x & (l ≥ 0xe0) || continue

        (i += 1) ≤ n || return c
        b = codeunit(s, i) # cont byte 2
        c -= (x = b & 0xc0 == 0x80)
        x & (l ≥ 0xf0) || continue

        (i += 1) ≤ n || return c
        b = codeunit(s, i) # cont byte 3
        c -= (b & 0xc0 == 0x80)
    end
end

# Parsers.xparse
function Parsers.xparse(::Type{T}, source::Union{AbstractVector{UInt8}, IO}, pos, len, options::Parsers.Options, ::Type{S}=T)::Parsers.Result{S} where {T <: InlineString, S}
    res = Parsers.xparse(String, source, pos, len, options)
    code = res.code
    overflowed = false
    poslen = res.val
    if !Parsers.valueok(code) || Parsers.sentinel(code)
        x = T()
    else
        poslen = res.val
        if T === InlineString1
            if poslen.len != 1
                overflowed = true
                x = T()
            else
                Parsers.fastseek!(source, poslen.pos)
                x = InlineString1(Parsers.peekbyte(source, poslen.pos))
                Parsers.fastseek!(source, pos + res.tlen - 1)
            end
        elseif Parsers.escapedstring(code) || !(source isa AbstractVector{UInt8})
            if poslen.len > (sizeof(T) - 1)
                overflowed = true
                x = T()
            else
                # manually build up InlineString
                i = poslen.pos
                maxi = i + poslen.len
                x = T()
                Parsers.fastseek!(source, i - 1)
                while i < maxi
                    b = Parsers.peekbyte(source, i)
                    if b == options.e
                        i += 1
                        Parsers.incr!(source)
                        b = Parsers.peekbyte(source, i)
                    end
                    x, overflowed = addcodeunit(x, b)
                    i += 1
                    Parsers.incr!(source)
                end
                Parsers.fastseek!(source, maxi)
            end
        else
            vlen = poslen.len
            if vlen > (sizeof(T) - 1)
                # @show T, vlen, sizeof(T)
                overflowed = true
                x = T()
            else
                # @show poslen.pos, vlen
                x = T(source, poslen.pos, vlen)
            end
        end
    end
    if overflowed
        code |= Parsers.OVERFLOW
    end
    return Parsers.Result{S}(code, res.tlen, x)
end

## InlineString sorting
using Base.Sort, Base.Order

# Only small-ish InlineStrings benefit from RadixSort algorithm
const SmallInlineStrings = Union{String1, String3, String7, String15}

# And under certain thresholds, MergeSort is faster than RadixSort, even for small InlineStrings
const MergeSortThresholds = Dict(
    1 => 2^5,
    4 => 2^7,
    8 => 2^9,
    16 => 2^23
)

struct InlineStringSortAlg <: Algorithm end
const InlineStringSort = InlineStringSortAlg()

Base.Sort.defalg(::AbstractArray{<:Union{SmallInlineStrings, Missing}}) = InlineStringSort

struct Radix
    size::Int
    pow::Int
    mask::UInt16
end

Radix(size) = Radix(size, 2^size, typemax(UInt16) >> (16 - size))

sortvalue(o::By,   x     ) = sortvalue(Forward, o.by(x))
sortvalue(o::Perm, i::Int) = sortvalue(o.order, o.data[i])
sortvalue(o::Lt,   x     ) = error("sortvalue does not work with general Lt Orderings")
sortvalue(rev::ReverseOrdering, x) = Base.not_int(sortvalue(rev.fwd, x))
sortvalue(::Base.ForwardOrdering, x) = x

_oftype(::Type{T}, x::S) where {T, S} = sizeof(T) == sizeof(S) ? Base.bitcast(T, x) : sizeof(T) > sizeof(S) ? Base.zext_int(T, x) : Base.trunc_int(T, x)

radix(v::T, j, radix_size, radix_mask) where {T} = _oftype(Int64, Base.and_int(Base.lshr_int(v, (j - 1) * radix_size), _oftype(T, radix_mask))) + 1

@noinline requireprimitivetype(T) = throw(ArgumentError("InlineStringSort requires isprimitivetype input: `$T` invalid"))

function Base.sort!(vs::AbstractVector, lo::Int, hi::Int, ::InlineStringSortAlg, o::Ordering)
    # Input checking
    lo >= hi && return vs

    # Make sure we're sorting a primitive type
    T = Base.Order.ordtype(o, vs)
    isprimitivetype(Base.nonmissingtype(T)) || requireprimitivetype(T)

    if hi - lo < MergeSortThresholds[sizeof(T)]
        return sort!(vs, lo, hi, MergeSort, o)
    end

    # setup
    ts = similar(vs)
    rdx = Radix(sizeof(T) == 1 ? 8 : 11)
    radix_size = rdx.size
    radix_mask = rdx.mask
    radix_size_pow = rdx.pow
    # iters is the # of 11-bit chunks we split each element up into
    # they each represent a "significant digit" we'll be sorting on
    iters = cld(sizeof(T) * 8, radix_size)
    # bin has a row for each unique 11-bit pattern
    # and a column for each 11-bit chunk we'll split each element up into
    bin = zeros(UInt32, radix_size_pow, iters)
    # if for some reason our lo isn't 1, we want to start our
    # 1st row bin values as the 1st index we'll start at in the output
    # i.e. we're assuming firstindex(vs):(lo - 1) is already sorted
    if lo > 1;  bin[1, :] .= lo-1; end

    # for each element, split into 11-bit chunks (radix)
    # and accumulate counts per unique pattern in bin
    for i = lo:hi
        v = sortvalue(o, vs[i])
        for j = 1:iters
            idx = radix(v, j, radix_size, radix_mask)
            @inbounds bin[idx, j] += 1
        end
    end

    # now we sort elements by sorting each radix using counting sort
    swaps = 0
    len = hi - lo + 1
    @inbounds for j = 1:iters
        # we first check if the radix for each element happened to be
        # the exact same bit pattern; if so, they're "already sorted"
        # for this radix and we can skip to the next. This would be common
        # if we, for example, had many small integer values stored in Int64
        # which would result in many "wasted" zero bits in most elements
        v = sortvalue(o, vs[hi])
        idx = radix(v, j, radix_size, radix_mask)

        # if every element was counted at this bit pattern
        # we can skip to the next radix chunk
        bin[idx, j] == len && continue

        # otherwise, we perform the counting sort for this radix
        # by doing a cumulative sum for this radix column in bin
        x = bin[1, j]
        for i = 2:radix_size_pow
            x += bin[i, j]
            bin[i, j] = x
        end
        # now we extract the output index for our 1st element (vs[hi])
        ci = bin[idx, j]
        # and decrement the count for that bit pattern which
        # will result in a subsequent identical bit pattern being
        # placed one index ahead of the current one
        bin[idx, j] -= 1
        ts[ci] = vs[hi]

        # now we sort the rest of the elements' radix similarly
        for i in (hi - 1):-1:lo
            v = sortvalue(o, vs[i])
            idx = radix(v, j, radix_size, radix_mask)
            ci = bin[idx, j]
            bin[idx, j] -= 1
            ts[ci] = vs[i]
        end
        # we keep 2 arrays, vs and ts
        # because we can't overwrite where the current
        # element will go in the output before we've sorted
        # the element already there
        vs, ts = ts, vs
        swaps += 1
    end

    if isodd(swaps)
        vs, ts = ts, vs
        @inbounds for i = lo:hi
            vs[i] = ts[i]
        end
    end
    return vs
end

# collections of InlineStrings
"""
    inlinestrings(itr) => Vector

    Utility function that takes any iterator of `AbstractString` values
and attempts to produce a `Vector` with a single promoted `InlineString` type. That is,
all iterated elements will be promoted to the smallest `InlineString` subtype
that can fit all elements. If any value is larger than the current largest InlineString
type (256 bytes), the entire collection will be promoted to `String` instead.
`missing` values are also allowed and will result in a result eltype of `Union{Missing, X}`
where `X` is an `InlineString` subtype or `String`.
"""
function inlinestrings(itr::T) where {T}
    # x must be iterable
    IS = Base.IteratorSize(T)
    state = iterate(itr)
    state === nothing && return []
    y, st = state
    x = y === missing ? missing : sizeof(y) < 256 ? InlineString(y) : String(y)
    eT = typeof(x)
    # allocate res, which will either be same length as `itr` if
    # IS <: HasLength, or length of 0 if Base.SizeUnknown
    res = allocate(eT, IS, itr)
    i = 1
    # set! push!-es for Base.SizeUnknown, or setindex! for HasLength
    set!(IS, res, x, i)
    i += 1
    # dispatch to separate function for type stability
    return _inlinestrings(itr, st, eT, IS, res, i)
end

const HasLength = Union{Base.HasShape, Base.HasLength}
allocate(::Type{T}, ::HasLength, itr) where {T} = Vector{T}(undef, length(itr))
allocate(::Type{T}, IS, itr) where {T} = Vector{T}(undef, 0)
set!(::HasLength, res, x, i) = setindex!(res, x, i)
set!(IS, res, x, i) = push!(res, x)

function _inlinestrings(itr, st, ::Type{eT}, IS, res, i) where {eT}
    while true
        state = iterate(itr, st)
        state === nothing && break
        y, st = state
        if y === missing && eT >: Missing
            set!(IS, res, missing, i)
        elseif y !== missing && eT !== Missing && (sizeof(y) < sizeof(eT) || sizeof(y) == 1)
            set!(IS, res, Base.nonmissingtype(eT)(y), i)
        else
            # need to promote and widen res,
            # then re-dispatch on _inlinestrings for new eltype
            x = y === missing ? missing : sizeof(y) < 256 ? InlineString(y) : String(y)
            new_eT = promote_type(typeof(x), eT)
            newres = allocate(new_eT, Base.HasLength(), res)
            copyto!(newres, 1, res, 1, i - 1)
            set!(IS, newres, x, i)
            return _inlinestrings(itr, st, new_eT, IS, newres, i + 1)
        end
        i += 1
    end
    return res
end

Base.Broadcast.broadcasted(::Type{InlineString}, A::AbstractArray) = inlinestrings(A)
Base.map(::Type{InlineString}, A::AbstractArray) = inlinestrings(A)
Base.collect(::Type{InlineString}, A::AbstractArray) = inlinestrings(A)

end # module