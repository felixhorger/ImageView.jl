module ImageView
if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@optlevel"))
    @eval Base.Experimental.@optlevel 1
end
if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@max_methods"))
    @eval Base.Experimental.@max_methods 1
end

using ImageCore, ImageBase, StatsBase
using ImageCore.MappedArrays
using MultiChannelColors
using RoundingIntegers
using Gtk4, GtkObservables, Graphics, Cairo
using Gtk4: Align_START, Align_END, Align_FILL
using GtkObservables.Observables
using AxisArrays: AxisArrays, Axis, AxisArray, axisnames, axisvalues, axisdim
using ImageMetadata
using Compat # for @constprop :none
using Random

export AnnotationText, AnnotationPoint, AnnotationPoints,
       AnnotationLine, AnnotationLines, AnnotationBox
export CLim, annotate!, annotations, canvasgrid, imshow, imshow!, imshow_gui, imlink,
       scalebar, slice2d

const AbstractGray{T} = Color{T,1}
const GrayLike = Union{AbstractGray,Number}
const FixedColorant{T<:FixedPoint} = Colorant{T}
const Annotations = Observable{Dict{UInt,Any}}

include("slicing.jl")

"""
    CLim(cmin, cmax)

Specify contrast limits where `x <= cmin` will be rendered as black,
and `x >= cmax` will be rendered as white.
"""
struct CLim{T}
    min::T
    max::T
end
CLim(min, max) = CLim(promote(min, max)...)
Base.convert(::Type{CLim{T}}, clim::CLim) where {T} = CLim(convert(T, clim.min),
                                                           convert(T, clim.max))
Base.eltype(::CLim{T}) where {T} = T

"""
    closeall()

Closes all windows opened by ImageView.
"""
function closeall()
    for (w, _) in window_wrefs
        destroy(w)
    end
    empty!(window_wrefs)
    nothing
end

const window_wrefs = WeakKeyDict{Gtk4.GtkWindowLeaf,Nothing}()

"""
    imshow()

Choose an image to display via a file dialog.
"""
imshow() = imshow(load(open_dialog("Pick an image to display")))

"""
    imshow!(canvas, img) -> drawsignal
    imshow!(canvas, img::Observable, zr::Observable{ZoomRegion}) -> drawsignal
    imshow!(frame::Frame, canvas, img::Observable, zr::Observable{ZoomRegion}) -> drawsignal
    imshow!(..., anns=annotations())

Display the image `img`, in the specified `canvas`. Use the version
with `zr` if you have already turned on rubber-banding or other
pan/zoom interactivity for `canvas`. Returns the Observables `drawsignal`
used for updating the canvas.

If you supply `frame`, then the pixel aspect ratio will be set to that
of `pixelspacing(img)`.

With any of these forms, you may optionally supply `annotations`.

This only creates the `draw` method for `canvas`; mouse- or key-based
interactivity can be set up via [`imshow`](@ref) or, at a lower level,
using GtkObservables's tools:

- `init_zoom_rubberband`
- `init_zoom_scroll`
- `init_pan_scroll`
- `init_pan_drag`

# Example

```julia
using ImageView, GtkObservables, Gtk4, TestImages
# Create a window with a canvas in it
win = GtkWindow()
c = canvas(UserUnit)
push!(win, c)
# Load images
mri = testimage("mri")
# Display the image
imshow!(c, mri[:,:,1])
# Update with a different image
imshow!(c, mri[:,:,8])
"""
function imshow!(canvas::GtkObservables.Canvas{UserUnit},
                 imgsig::Observable,
                 zr::Observable{ZoomRegion{T}},
                 annotations::Annotations=annotations()) where T<:RInteger
    draw(canvas, imgsig, annotations) do cnvs, image, anns
        copy_with_restrict!(cnvs, image)
        set_coordinates(cnvs, zr[])
        draw_annotations(cnvs, anns)
    end
end

function imshow!(frame::Union{GtkFrame,GtkAspectFrame},
                 canvas::GtkObservables.Canvas{UserUnit},
                 imgsig::Observable,
                 zr::Observable{ZoomRegion{T}},
                 annotations::Annotations=annotations()) where T<:RInteger
    draw(canvas, imgsig, annotations) do cnvs, image, anns
        copy_with_restrict!(cnvs, image)
        set_coordinates(cnvs, zr[])
        set_aspect!(frame, image)
        draw_annotations(cnvs, anns)
        nothing
    end
end

# Without a ZoomRegion, there's no risk that the apsect ratio needs to
# change dynamically, so it can be set once and left. Consequently we
# don't need `frame` variants of the remaining methods.
function imshow!(canvas::GtkObservables.Canvas,
                 imgsig::Observable,
                 annotations::Annotations=annotations())
    draw(canvas, imgsig, annotations) do cnvs, image, anns
        copy_with_restrict!(cnvs, image)
        set_coordinates(cnvs, axes(image))
        draw_annotations(cnvs, anns)
    end
end

# Simple non-interactive image display
function imshow!(canvas::GtkObservables.Canvas,
                 img::AbstractMatrix,
                 annotations::Annotations=annotations())
    draw(canvas, annotations) do cnvs, anns
        copy_with_restrict!(cnvs, img)
        set_coordinates(cnvs, axes(img))
        draw_annotations(cnvs, anns)
    end
    nothing
end

function copy_with_restrict!(cnvs, img::AbstractMatrix)
    imgsz = size(img)
    while (imgsz[1] > 2*Graphics.height(cnvs) && imgsz[2] > 2*Graphics.width(cnvs))
        img = restrict(img)
        imgsz = size(img)
    end
    copy!(cnvs, img)
end

"""
    imshow(img; axes=(1,2), name="ImageView") -> guidict
    imshow(img, clim; kwargs...) -> guidict
    imshow(img, clim, zoomregion, slicedata, annotations; kwargs...) -> guidict

Display the image `img` in a new window titled with `name`, returning
a dictionary `guidict` containing any Observables signals or GtkObservables
widgets. If the image is 3 or 4 dimensional, GUI controls will be
added for slicing along "extra" axes. By default the two-dimensional
slice containing axes 1 and 2 are shown, but that can be changed by
passing a different setting for `axes`.

If the image is grayscale, by default contrast is set by a
`scaleminmax` object whose end-points can be modified by
right-clicking on the image. If `clim == nothing`, the image's own
native contrast is used (`clamp01nan`).  You may also pass a custom
contrast function.

Finally, you may specify [`GtkObservables.ZoomRegion`](@ref) and
[`SliceData`](@ref) signals. See also [`roi`](@ref), as well as any
`annotations` that you wish to apply.

Other supported keyword arguments include:
- `scalei=identity` as an intensity-scaling function prior to display
- `aspect=:auto` to control the aspect ratio of the image
- `flipx=false`, `flipy=false` to flip axes
- `canvassize=nothing` to control the size of the window (`nothing` chooses based on image size)
"""
Compat.@constprop :none function imshow(@nospecialize(img::AbstractArray);
                axes=default_axes(img), name="ImageView", scalei=identity, aspect=:auto,
                kwargs...)
    imgmapped, kwargs = kwhandler(_mappedarray(scalei, img), axes; kwargs...)
    zr, sd = roi(imgmapped, axes)
    #v = slice2d(imgmapped, zr[], sd)
    imshow(Base.inferencebarrier(imgmapped)::AbstractArray, default_clim(img), zr, sd; name=name, aspect=aspect, kwargs...)
end

imshow(img::AbstractVector; kwargs...) = (@nospecialize; imshow(reshape(img, :, 1); kwargs...))

function imshow(c::GtkObservables.Canvas, @nospecialize(img::AbstractMatrix), anns=annotations(); kwargs...)
    f = parent(widget(c))
    imshow(f, c, img, default_clim(img), roi(img, default_axes(img))..., anns; kwargs...)
end

Compat.@constprop :none function imshow(@nospecialize(img::AbstractArray), clim;
                axes = default_axes(img), name="ImageView", aspect=:auto, kwargs...)
    img, kwargs = kwhandler(img, axes; kwargs...)
    imshow(img, clim, roi(img, axes)...; name=name, aspect=aspect, kwargs...)
end

Compat.@constprop :none function imshow(@nospecialize(img::AbstractArray), clim,
                zr::Observable{ZoomRegion{T}}, sd::SliceData,
                anns=annotations();
                name="ImageView", aspect=:auto, canvassize::Union{Nothing,Tuple{Int,Int}}=nothing) where T
    v = slice2d(img, zr[], sd)
    ps = map(abs, pixelspacing(v))
    if canvassize === nothing
        canvassize = default_canvas_size(fullsize(zr[]), ps[2]/ps[1])
    end
    guidict = imshow_gui(canvassize, sd; name=name, aspect=aspect)
    guidict["hoverinfo"] = on(guidict["canvas"].mouse.motion) do btn
        hoverinfo(guidict["status"], btn, img, sd)
    end

    roidict = imshow(guidict["frame"], guidict["canvas"], img,
                     wrap_signal(clim), zr, sd, anns)

    win = guidict["window"]
    dct = Dict("gui"=>guidict, "clim"=>clim, "roi"=>roidict, "annotations"=>anns)
    GtkObservables.gc_preserve(win, dct)
    return dct
end

function imshow(frame::Union{Gtk4.GtkFrame,Gtk4.GtkAspectFrame}, canvas::GtkObservables.Canvas,
                @nospecialize(img::AbstractArray), clim::Union{Nothing,Observable{<:CLim}},
                zr::Observable{ZoomRegion{T}}, sd::SliceData,
                anns::Annotations=annotations()) where T
    imgsig = map(zr, sd.signals...) do r, s...
        @nospecialize
        while length(s) < 2
            s = (s..., 1)
        end
        for (h, ann) in anns[]
            setvalid!(ann, s...)
        end
        slice2d(img, r, sd)
    end
    set_aspect!(frame, imgsig[])
    imgc = prep_contrast(canvas, imgsig, clim)
    GtkObservables.gc_preserve(frame, imgc)
    # If there is an error in one of the functions being mapped elementwise, we often don't
    # discover it until it triggers an error inside `Gtk4.draw`. Check for problems here so
    # such errors become easier to debug.
    if !supported_eltype(imgc[])
        !supported_eltype(imgsig[]) && error("got unsupported eltype $(eltype(imgsig[])) in creating slice")
        error("got unsupported eltype $(eltype(imgc[])) in preparing the constrast")
    end

    roidict = imshow(frame, canvas, imgc, zr, anns)
    roidict["slicedata"] = sd
    roidict
end

# For things that are not AbstractArrays, we don't offer the clim
# option.  We also don't display hoverinfo, as there is no guarantee
# that one can quickly compute intensities at a point.
Compat.@constprop :none function imshow(img;
                axes = default_axes(img), name="ImageView", aspect=:auto)
    @nospecialize
    zr, sd = roi(img, axes)
    imshow(img, zr, sd; name=name, aspect=aspect)
end

Compat.@constprop :none function imshow(img,
                zr::Observable{ZoomRegion{T}}, sd::SliceData,
                anns=annotations();
                name="ImageView", aspect=:auto) where T
    @nospecialize
    v = slice2d(img, zr[], sd)
    ps = map(abs, pixelspacing(v))
    csz = default_canvas_size(fullsize(zr[]), ps[2]/ps[1])
    guidict = imshow_gui(csz, sd; name=name, aspect=aspect)

    roidict = imshow(guidict["frame"], guidict["canvas"], img, zr, sd, anns)

    win = guidict["window"]
    dct = Dict("gui"=>guidict, "roi"=>roidict)
    GtkObservables.gc_preserve(win, dct)
    return dct
end

function imshow(frame::Union{GtkFrame,GtkAspectFrame}, canvas::GtkObservables.Canvas,
                img, zr::Observable{ZoomRegion{T}}, sd::SliceData,
                anns::Annotations=annotations()) where T
    @nospecialize
    imgsig = map(zr, sd.signals...) do r, s...
        @nospecialize
        slice2d(img, r, sd)
    end
    set_aspect!(frame, imgsig[])
    GtkObservables.gc_preserve(frame, imgsig)

    roidict = imshow(frame, canvas, imgsig, zr, anns)
    roidict["slicedata"] = sd
    GtkObservables.gc_preserve(frame, roidict)
    roidict
end

function close_cb(::Ptr, par, win)
    @idle_add Gtk4.destroy(win)
    nothing
end

function closeall_cb(::Ptr, par, win)
    @idle_add closeall()
    nothing
end

function fullscreen_cb(aptr::Ptr, par, win)
    gv=Gtk4.GLib.GVariant(par)
    a=convert(Gtk4.GLib.GSimpleAction, aptr)
    if gv[Bool]
        @idle_add Gtk4.fullscreen(win)
    else
        @idle_add Gtk4.unfullscreen(win)
    end
    Gtk4.GLib.set_state(a, gv)
    nothing
end

"""
    guidict = imshow_gui(canvassize, gridsize=(1,1); name="ImageView", aspect=:auto, slicedata=SliceData{false}())

Create an image-viewer GUI. By default creates a single canvas, but
with custom `gridsize = (nx, ny)` you can create a grid of canvases.
`canvassize = (szx, szy)` describes the desired size of the (or each) canvas.

Optionally provide a `name` for the window.
`aspect` should be `:auto` or `:none`, with the former preserving the pixel aspect ratio
as the window is resized.
`slicedata` is an object created by [`roi`](@ref) that encodes
the necessary information for creating player widgets for viewing
multidimensional images.
"""
Compat.@constprop :none function imshow_gui(canvassize::Tuple{Int,Int},
                    gridsize::Tuple{Int,Int} = (1,1);
                    name = "ImageView", aspect=:auto,
                    slicedata::SliceData=SliceData{false}())
    winsize = canvas_size(screen_size(), map(*, canvassize, gridsize))
    win = GtkWindow(name, winsize...)
    ag = Gtk4.GLib.GSimpleActionGroup()
    m = Gtk4.GLib.GActionMap(ag)
    push!(win, Gtk4.GLib.GActionGroup(ag), "win")
    Gtk4.GLib.add_action(m, "close", close_cb, win)
    Gtk4.GLib.add_action(m, "closeall", closeall_cb, nothing)
    Gtk4.GLib.add_stateful_action(m, "fullscreen", false, fullscreen_cb, win)
    sc = GtkShortcutController(win)
    Gtk4.add_action_shortcut(sc,Sys.isapple() ? "<Meta>W" : "<Control>W", "win.close")
    Gtk4.add_action_shortcut(sc,Sys.isapple() ? "<Meta><Shift>W" : "<Control><Shift>W", "win.closeall")
    Gtk4.add_action_shortcut(sc,Sys.isapple() ? "<Meta><Shift>F" : "F11", "win.fullscreen")

    window_wrefs[win] = nothing
    signal_connect(win, :destroy) do w
        delete!(window_wrefs, win)
    end
    vbox = GtkBox(:v)
    push!(win, vbox)
    if gridsize == (1,1)
        frames, canvases = frame_canvas(aspect)
        g = frames
    else
        g, frames, canvases = canvasgrid(gridsize, aspect)
    end
    push!(vbox, g)
    status = GtkLabel("")
    set_gtk_property!(status, :halign, Gtk4.Align_START)
    push!(vbox, status)

    guidict = Dict("window"=>win, "vbox"=>vbox, "frame"=>frames, "status"=>status,
                   "canvas"=>canvases)

    # Add the player controls
    if !isempty(slicedata)
        players = [player(slicedata.signals[i], axisvalues(slicedata.axs[i])[1]; id=i) for i = 1:length(slicedata)]
        guidict["players"] = players
        hbox = GtkBox(:h)
        for p in players
            push!(hbox, frame(p))
        end
        push!(guidict["vbox"], hbox)
    end

    guidict
end

imshow_gui(canvassize::Tuple{Int,Int}, slicedata::SliceData, args...; kwargs...) =
    imshow_gui(canvassize, args...; slicedata=slicedata, kwargs...)

fullsize(zr::ZoomRegion) =
    map(i->length(UnitRange{Int}(i)), (zr.fullview.y, zr.fullview.x))

"""
    grid, frames, canvases = canvasgrid((ny, nx))

Create a grid of `ny`-by-`nx` canvases for drawing. `grid` is a
GtkGrid layout, `frames` is an `ny`-by-`nx` array of
GtkAspectRatioFrames that contain each canvas, and `canvases` is an
`ny`-by-`nx` array of canvases.
"""
Compat.@constprop :none function canvasgrid(gridsize::Tuple{Int,Int}, aspect=:auto)
    g = GtkGrid()
    frames = Matrix{Any}(undef, gridsize)
    canvases = Matrix{Any}(undef, gridsize)
    for j = 1:gridsize[2], i = 1:gridsize[1]
        f, c = frame_canvas(aspect)
        g[j,i] = f
        frames[i,j] = f
        canvases[i,j] = c
    end
    return g, frames, canvases
end

Compat.@constprop :none function frame_canvas(aspect)
    f = aspect==:none ? GtkFrame() : GtkAspectFrame(0.5, 0.5, 1, false)
    Gtk4.G_.set_css_classes(f, ["squared"])  # remove rounded corners (see __init__)
    set_gtk_property!(f, :hexpand, true)
    set_gtk_property!(f, :vexpand, true)
    c = canvas(UserUnit,10,10)  # set minimum size of 10x10 pixels
    f[] = widget(c)
    f, c
end

"""
    imshow(canvas, imgsig::Observable) -> guidict
    imshow(canvas, imgsig::Observable, zr::Observable{ZoomRegion}) -> guidict
    imshow(frame::Frame, canvas, imgsig::Observable, zr::Observable{ZoomRegion}) -> guidict

Display `imgsig` (a `Observable` of an image) in `canvas`, setting up
panning and zooming. Optionally include a `frame` for preserving
aspect ratio. `imgsig` must be two-dimensional (but can be a
Observable-view of a higher-dimensional object).

# Example

```julia
using ImageView, TestImages, Gtk4
mri = testimage("mri");
# Create a canvas `c`. There are other approaches, like stealing one from a previous call
# to `imshow`, or using GtkObservables directly.
guidict = imshow_gui((300, 300))
c = guidict["canvas"];
# To see anything you have to call `showall` on the window (once)
# Create the image Observable
imgsig = Observable(mri[:,:,1]);
# Show it
imshow(c, imgsig)
# Now anytime you want to update, just reset with a new image
imgsig[] = mri[:,:,8]
```
"""
function imshow(canvas::GtkObservables.Canvas{UserUnit},
                imgsig::Observable,
                zr::Observable{ZoomRegion{T}}=Observable(ZoomRegion(imgsig[])),
                anns::Annotations=annotations()) where T<:RInteger
    @nospecialize
    zoomrb = init_zoom_rubberband(canvas, zr)
    zooms = init_zoom_scroll(canvas, zr)
    pans = init_pan_scroll(canvas, zr)
    pand = init_pan_drag(canvas, zr)
    redraw = imshow!(canvas, imgsig, zr, anns)
    dct = Dict("image roi"=>imgsig, "zoomregion"=>zr, "zoom_rubberband"=>zoomrb,
               "zoom_scroll"=>zooms, "pan_scroll"=>pans, "pan_drag"=>pand,
               "redraw"=>redraw)
    GtkObservables.gc_preserve(widget(canvas), dct)
    dct
end

function imshow(frame::Union{GtkFrame,GtkAspectFrame},
                canvas::GtkObservables.Canvas{UserUnit},
                imgsig::Observable,
                zr::Observable{ZoomRegion{T}},
                anns::Annotations=annotations()) where T<:RInteger
    @nospecialize
    zoomrb = init_zoom_rubberband(canvas, zr)
    zooms = init_zoom_scroll(canvas, zr)
    pans = init_pan_scroll(canvas, zr)
    pand = init_pan_drag(canvas, zr)
    redraw = imshow!(frame, canvas, imgsig, zr, anns)
    dct = Dict("image roi"=>imgsig, "zoomregion"=>zr, "zoom_rubberband"=>zoomrb,
               "zoom_scroll"=>zooms, "pan_scroll"=>pans, "pan_drag"=>pand,
               "redraw"=>redraw)
    GtkObservables.gc_preserve(widget(canvas), dct)
    dct
end

"""
    imshowlabeled(img, label)

Display `img`, but showing the pixel's `label` rather than the color
value in the status bar.
"""
function imshowlabeled(img::AbstractArray, label::AbstractArray; proplist...)
    @nospecialize
    axes(img) == axes(label) || throw(DimensionMismatch("axes $(axes(label)) of label array disagree with axes $(axes(img)) of the image"))
    guidict = imshow(img; proplist...)
    gui = guidict["gui"]
    sd = guidict["roi"]["slicedata"]
    off(gui["hoverinfo"])
    gui["hoverinfo"] = on(gui["canvas"].mouse.motion) do btn
        hoverinfo(gui["status"], btn, label, sd)
    end
    guidict
end

function hoverinfo(lbl, btn, img, sd::SliceData{transpose}) where transpose
    io = IOBuffer()
    y, x = round(Int, btn.position.y.val), round(Int, btn.position.x.val)
    axes = sliceinds(img, transpose ? (x, y) : (y, x), makeslices(sd)...)
    if checkbounds(Bool, img, axes...)
        print(io, '[', y, ',', x, "] ")
        show(IOContext(io, :compact=>true), img[axes...])
        set_gtk_property!(lbl, :label, String(take!(io)))
    else
        set_gtk_property!(lbl, :label, "")
    end
end

function fast_finite_extrema(a::AbstractArray{T}) where T
    mini = typemax(T)
    maxi = typemin(T)
    @simd for v in a
        if isfinite(v)
            if v <= mini
                mini = v
            end
            if v > maxi
                maxi = v
                # Needs to have a separate if-block,
                # for the case that all values in a are equal
            end
        end
    end
    return mini, maxi
end
function valuespan(img::AbstractArray; checkmax=10^8)
    if length(img) > checkmax
        img = randsubseq(img, checkmax / length(img))
    end
    minval, maxval = fast_finite_extrema(img)
    invalid_min, invalid_max = (!isfinite).((minval, maxval))
    (invalid_min || invalid_max) && @warn "Could not determine valid value span"
    if invalid_min && invalid_max
        minval = 0
        maxval = 1
    elseif invalid_min
        minval = maxval - 1
    elseif invalid_max
        maxval = minval + 1
    elseif minval == maxval
        maxval = minval + 1
    end
    return minval, maxval
end

default_clim(img) = nothing
default_clim(img::AbstractArray{C}) where {C<:GrayLike} = _default_clim(img, eltype(C))
default_clim(img::AbstractArray{C}) where {C<:AbstractRGB} = _default_clim(img, eltype(C))
default_clim(img::AbstractArray{C}) where {C<:AbstractMultiChannelColor} = _default_clim(img, eltype(C))
_default_clim(img, ::Type{Bool}) = nothing
_default_clim(img, ::Type{T}) where {T} = _deflt_clim(img)
function _deflt_clim(img::AbstractArray)
    minval, maxval = valuespan(img)
    Observable(CLim(saferound(gray(minval)), saferound(gray(maxval))))
end
function _deflt_clim(img::AbstractArray{T}) where {T<:AbstractRGB}
    minval = RGB(0.0,0.0,0.0)
    maxval = RGB(1.0,1.0,1.0)
    Observable(CLim(minval, maxval))
end

function _deflt_clim(img::AbstractMatrix{C}) where {C<:AbstractMultiChannelColor}
    minval = zero(C)
    maxval = oneunit(C)
    Observable(CLim(minval, maxval))
end

saferound(x::Integer) = convert(RInteger, x)
saferound(x) = x

default_axes(::AbstractVector) = (1,)
default_axes(img) = (1, 2)
default_axes(img::AxisArray) = axisnames(img)[[1,2]]

#default_view(img) = view(img, :, :, ntuple(d->1, ndims(img)-2)...)
#default_view(img::Observable) = default_view(img[])

# default_slices(img) = ntuple(d->PlayerInfo(Observable(1), axes(img, d+2)), ndims(img)-2)

function histsignals(enabled::Observable{Bool}, img::Observable, clim::Observable{CLim{T}}) where {T<:GrayLike}
    image, cl = img[], clim[]
    Th = float(promote_type(T, eltype(image)))
    function computehist(image, cl)
        smin, smax = valuespan(image)
        smin = float(min(smin, cl.min))
        smax = float(max(smax, cl.max))
        rng = LinRange(Th(smin), Th(smax), 300)
        fit(Histogram, mappedarray(nanz, vec(channelview(image))), rng; closed=:right)
    end
    histsig = Observable(enabled[] ? computehist(image, cl) :
                                     Histogram(LinRange(Th(cl.min), Th(cl.max), 2), [length(image)], :right, false))
    map!(histsig, img, enabled) do image, en  # `enabled` fixes issue #168
        if en
            computehist(image, clim[])
        else
            histsig[]
        end
    end
    return [histsig]
end

channel_clim(f, clim::CLim{C}) where {C<:Colorant} = CLim(f(clim.min), f(clim.max))
channel_clims(clim::CLim{T}) where {T<:AbstractRGB} = map(f->channel_clim(f, clim), (red, green, blue))
channel_clims(clim::CLim{C}) where {C<:AbstractMultiChannelColor} = map(f->channel_clim(f, clim), ntuple(i -> (c -> Tuple(c)[i]), length(C)))

function mapped_channel_clims(clim::Observable{CLim{T}}) where {T<:AbstractRGB}
    inits = channel_clims(clim[])
    rsig = map!(x->channel_clim(red, x), Observable(inits[1]), clim)
    gsig = map!(x->channel_clim(green, x), Observable(inits[1]), clim)
    bsig = map!(x->channel_clim(blue, x), Observable(inits[1]), clim)
    return [rsig;gsig;bsig]
end

function histsignals(enabled::Observable{Bool}, img::Observable, clim::Observable{CLim{T}}) where {T<:AbstractRGB}
    rv = map(x->mappedarray(red, x), img)
    gv = map(x->mappedarray(green,x), img)
    bv = map(x->mappedarray(blue, x), img)
    cls = mapped_channel_clims(clim) #note currently this gets called twice, also in contrast gui creation (a bit inefficient/awkward)
    histsigs = []
    push!(histsigs, histsignals(enabled, rv, cls[1])[1])
    push!(histsigs, histsignals(enabled, gv, cls[2])[1])
    push!(histsigs, histsignals(enabled, bv, cls[3])[1])
    return histsigs
end

function mapped_channel_clims(clim::Observable{CLim{C}}) where {C<:AbstractMultiChannelColor}
    inits = channel_clims(clim[])
    return [map!(x -> channel_clim(c -> Tuple(c)[i], x), Observable(inits[1]), clim) for i = 1:length(C)]
end

function histsignals(enabled::Observable{Bool}, img::Observable, clim::Observable{CLim{C}}) where {C<:AbstractMultiChannelColor}
    chanarrays = [map(x->mappedarray(c -> Tuple(c)[i], x), img) for i = 1:length(C)]
    cls = mapped_channel_clims(clim) #note currently this gets called twice, also in contrast gui creation (a bit inefficient/awkward)
    histsigs = [histsignals(enabled, chanarrays[i], cls[i])[1] for i = 1:length(C)]
    return histsigs
end

function scalechannels(::Type{Tout}, cmin::AbstractRGB{T}, cmax::AbstractRGB{T}) where {T,Tout}
    r = scaleminmax(T, red(cmin), red(cmax))
    g = scaleminmax(T, green(cmin), green(cmax))
    b = scaleminmax(T, blue(cmin), blue(cmax))
    return x->Tout(nanz(r(red(x))), nanz(g(green(x))), nanz(b(blue(x))))
end
scalechannels(::Type{Tout}, cmin::C, cmax::C) where {Tout, C<:Union{Number,AbstractGray}} = scaleminmax(Tout, cmin, cmax)

function safeminmax(cmin::T, cmax::T) where {T<:GrayLike}
    if !(cmin < cmax)
        cmax = cmin+1
    end
    return cmin, cmax
end

function safeminmax(cmin::T, cmax::T) where {T<:AbstractRGB}
    rmin, rmax = safeminmax(red(cmin), red(cmax))
    gmin, gmax = safeminmax(green(cmin), green(cmax))
    bmin, bmax = safeminmax(blue(cmin), blue(cmax))
    return T(rmin, gmin, bmin), T(rmax, gmax, bmax)
end

function scalechannels(::Type{Tout}, cmin::AbstractMultiChannelColor{T}, cmax::AbstractMultiChannelColor{T}) where {T,Tout}
    return x->Tout(ntuple(i -> nanz(scaleminmax(T, Tuple(cmin)[i], Tuple(cmax)[i])(Tuple(x)[i])), length(cmin)))
end

function safeminmax(cmin::C, cmax::C) where {C<:AbstractMultiChannelColor}
    minmaxpairs = ntuple(i -> safeminmax(Tuple(cmin)[i], Tuple(cmax)[i]), length(C))
    return C(first.(minmaxpairs)), C(last.(minmaxpairs))
end

function prep_contrast(@nospecialize(img::Observable), clim::Observable{CLim{T}}) where {T}
    # Set up the signals to calculate the histogram of intensity
    enabled = Observable(false) # skip hist calculation if the contrast gui isn't open
    histsigs = histsignals(enabled, img, clim)
    # Return a signal corresponding to the scaled image
    imgc = map(img, clim) do image, cl
        cmin, cmax = safeminmax(cl.min, cl.max)
        smm = scalechannels(outtype(T), cmin, cmax)
        mappedarray(smm, image)
    end
    enabled, histsigs, imgc
end

outtype(::Type{T}) where T<:GrayLike         = Gray{N0f8}
outtype(::Type{C}) where C<:Color            = RGB{N0f8}
outtype(::Type{C}) where C<:AbstractMultiChannelColor = C
outtype(::Type{C}) where C<:TransparentColor = RGBA{N0f8}

function prep_contrast(canvas, @nospecialize(img::Observable), clim::Observable{CLim{T}}) where T
    enabled, histsigs, imgsig = prep_contrast(img, clim)
    # Set up the right-click to open the contrast gui
    push!(canvas.preserved, create_contrast_popup(canvas, enabled, histsigs, clim))
    imgsig
end

prep_contrast(canvas, img::Observable, f) =
    map(image->mappedarray(f, image), img)
prep_contrast(canvas, img::Observable{A}, ::Nothing) where {A<:AbstractArray} =
    prep_contrast(canvas, img, clamp01nan)
prep_contrast(canvas, img::Observable, ::Nothing) = img

nanz(x) = ifelse(isnan(x), zero(x), x)
nanz(x::FixedPoint) = x
nanz(x::Integer) = x

const menuxml = """
<?xml version="1.0" encoding="UTF-8"?>
<interface>
  <menu id="context_menu">
    <item>
      <attribute name="label">Contrast...</attribute>
      <attribute name="action">canvas.contrast_gui</attribute>
    </item>
    <item>
      <attribute name="label">Save to file...</attribute>
      <attribute name="action">canvas.save</attribute>
    </item>
    <item>
      <attribute name="label">Copy to clipboard</attribute>
      <attribute name="action">canvas.copy</attribute>
    </item>
  </menu>
</interface>
"""

function create_contrast_popup(canvas, enabled, hists, clim)
    b = GtkBuilder(menuxml, -1)
    menumodel = b["context_menu"]::Gtk4.GLib.GMenuLeaf
    popupmenu = GtkPopoverMenu(menumodel)
    Gtk4.parent(popupmenu, widget(canvas))
    push!(canvas.preserved, on(canvas.mouse.buttonpress) do btn
        if btn.button == 3 && btn.clicktype == BUTTON_PRESS
            x,y = GtkObservables.convertunits(DeviceUnit, canvas, btn.position.x, btn.position.y)
            Gtk4.G_.set_pointing_to(popupmenu,Ref(Gtk4._GdkRectangle(round(Int32,x.val),round(Int32,y.val),1,1)))
            popup(popupmenu)
        end
    end)
    contrast_gui_action = Gtk4.GLib.GSimpleAction("contrast_gui", Nothing)
    push!(Gtk4.GLib.GActionMap(canvas.action_group), Gtk4.GLib.GAction(contrast_gui_action)) # replaces the old one if it exists
    signal_connect(contrast_gui_action, :activate) do a, par
        enabled[] = true
        @idle_add contrast_gui(enabled, hists, clim)
    end
end

function map_image_roi(@nospecialize(img), zr::Observable{ZoomRegion{T}}, slices...) where T
    map(zr, slices...) do r, s...
        cv = r.currentview
        view(img, UnitRange{Int}(cv.y), UnitRange{Int}(cv.x), s...)
    end
end
map_image_roi(img::Observable, zr::Observable{ZoomRegion{T}}, slices...) where {T} = img

function set_aspect!(frame::GtkAspectFrame, image)
    ps = map(abs, pixelspacing(image))
    sz = map(length, axes(image))
    r = sz[2]*ps[2]/(sz[1]*ps[1])
    set_gtk_property!(frame, :ratio, r)
    nothing
end
set_aspect!(frame, image) = nothing

"""
    default_canvas_size(imagesize, pixelaspectratio=1) -> (xsz, ysz)

Compute the canvas size for an image of size `imagesize` with the
defined `pixelaspectratio`. Note that `imagesize` is supplied in
coordinate order, i.e., (y, x) order, whereas the returned canvas size
is in Gtk order, i.e., (x, y) order.
"""
default_canvas_size(imgsz::Tuple{Integer,Integer}, pixelaspectratio::Number=1) =
    pixelaspectratio >= 1 ? (round(Int, pixelaspectratio*imgsz[2]), Int(imgsz[1])) :
        (Int(imgsz[2]), round(Int, imgsz[1]/pixelaspectratio))

"""
    canvas_size(win, requested_size) -> (xsz, ysz)
    canvas_size(screensize, requested_size) -> (xsz, ysz)

Limit the requested canvas size by the screen size. Both the output
and `screensize` are supplied in Gtk order (x, y).

When supplying a GtkWindow `win`, the canvas size is limited to 60% of
the total screen size.
"""
Compat.@constprop :none function canvas_size(win::Gtk4.GtkWindowLeaf, requestedsize_xy; minsize=100)
    ssz = screen_size(win)
    canvas_size(map(x->0.6*x, ssz), requestedsize_xy; minsize=minsize)
end

Compat.@constprop :none function canvas_size(screensize_xy, requestedsize_xy; minsize=100)
    f = minimum(map(/, screensize_xy, requestedsize_xy))
    if f > 1
        fmn = maximum(map(/, (minsize,minsize), requestedsize_xy))
        f = max(1, min(f, fmn))
    end
    (round(Int, f*requestedsize_xy[1]), round(Int, f*requestedsize_xy[2]))
end

Compat.@constprop :none function kwhandler(@nospecialize(img), axs; flipx=false, flipy=false, kwargs...)
    if flipx || flipy
        inds = AbstractRange[axes(img)...]
        setrange!(inds, _axisdim(img, axs[1]), flipy)
        setrange!(inds, _axisdim(img, axs[2]), flipx)
        img = view(img, inds...)
    end
    img, kwargs
end
function setrange!(inds, ax::Integer, flip)
    ind = inds[ax]
    inds[ax] = flip ? (last(ind):-1:first(ind)) : ind
    inds
end
_axisdim(img, ax::Integer) = ax
_axisdim(img, ax::Axis) = axisdim(img, ax)
_axisdim(img, ax) = axisdim(img, Axis{ax})


isgray(img::AbstractArray{T}) where {T<:Real} = true
isgray(img::AbstractArray{T}) where {T<:AbstractGray} = true
isgray(img) = false

_mappedarray(f, img) = mappedarray(f, img)
_mappedarray(f, img::AxisArray) = AxisArray(mappedarray(f, img.data), AxisArrays.axes(img))
_mappedarray(f, img::ImageMeta) = shareproperties(img, _mappedarray(f, data(img)))

wrap_signal(x) = Observable(x)
wrap_signal(x::Observable) = x
wrap_signal(::Nothing) = nothing

function supported_eltype(@nospecialize(img))
    T = eltype(img)
    return T <: Union{Number,Colorant} && T !== Union{}
end

include("link.jl")
include("contrast_gui.jl")
include("annotations.jl")

function __init__()
    # by default, GtkFrame and GtkAspectFrame use rounded corners
    # the way to override this is via custom CSS
    css="""
        .squared {border-radius: 0;}
    """
    cssprov=GtkCssProvider(css)
    push!(GdkDisplay(), cssprov, Gtk4.STYLE_PROVIDER_PRIORITY_APPLICATION)
end

using PrecompileTools
@compile_workload begin
    for T in (N0f8, N0f16, Float32)
        for C in (Gray, RGB)
            img = rand(C{T}, 2, 2)
            imshow(img)
            clim = ImageView.default_clim(img)
            imgsig = Observable(img)
            enabled, histsig, imgc = ImageView.prep_contrast(imgsig, clim)
            enabled[] = true
            ImageView.contrast_gui(enabled, histsig, clim)
        end
    end
    closeall()   # this is critical: you don't want to precompile with window_wrefs loaded with junk (dangling window pointers from closed session)
    sleep(1)   # avoid a "waiting for IO to finish" warning on 1.10
end

end # module
