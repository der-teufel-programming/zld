archive: ?[]const u8 = null,
path: []const u8,
mtime: u64,
data: []const u8,
index: File.Index,

header: ?macho.mach_header_64 = null,
sections: std.ArrayListUnmanaged(macho.section_64) = .{},
symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: []const u8 = &[0]u8{},
first_global: Symbol.Index = 0,

symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},
atoms: std.ArrayListUnmanaged(Atom.Index) = .{},

/// All relocations sorted and flatened, sorted by address ascending
/// per section.
relocations: std.ArrayListUnmanaged(macho.relocation_info) = .{},
data_in_code: std.ArrayListUnmanaged(macho.data_in_code_entry) = .{},
platform: ?MachO.Options.Platform = null,
dwarf_info: ?DwarfInfo = null,

alive: bool = true,
num_rebase_relocs: u32 = 0,
num_bind_relocs: u32 = 0,

output_symtab_ctx: MachO.SymtabCtx = .{},

pub fn deinit(self: *Object, gpa: Allocator) void {
    self.symtab.deinit(gpa);
    self.symbols.deinit(gpa);
    self.atoms.deinit(gpa);
    self.relocations.deinit(gpa);
    self.data_in_code.deinit(gpa);
    if (self.dwarf_info) |*dw| dw.deinit(gpa);
}

pub fn parse(self: *Object, macho_file: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = macho_file.base.allocator;
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    self.header = try reader.readStruct(macho.mach_header_64);

    const lc_seg = self.getLoadCommand(.SEGMENT_64) orelse return;
    const sections = lc_seg.getSections();
    try self.sections.ensureUnusedCapacity(gpa, sections.len);
    self.sections.appendUnalignedSliceAssumeCapacity(sections);

    const lc_symtab = self.getLoadCommand(.SYMTAB) orelse return;
    const cmd = lc_symtab.cast(macho.symtab_command).?;

    self.strtab = self.data[cmd.stroff..][0..cmd.strsize];

    const symtab = @as([*]align(1) const macho.nlist_64, @ptrCast(self.data.ptr + cmd.symoff))[0..cmd.nsyms];
    try self.symtab.ensureUnusedCapacity(gpa, symtab.len);
    self.symtab.appendUnalignedSliceAssumeCapacity(symtab);

    try self.initSectionAtoms(macho_file);
    try self.initSymbols(macho_file);

    // TODO split subsections if possible

    try self.initDataInCode(macho_file);

    // TODO ICF
    // TODO __eh_frame records

    self.initPlatform();
    try self.initDwarfInfo(gpa);

    if (try self.getSourceFilename(gpa)) |sf| {
        std.debug.print("{s}\n", .{sf});
    }
}

fn initSectionAtoms(self: *Object, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    try self.atoms.resize(gpa, self.sections.items.len);
    @memset(self.atoms.items, 0);

    for (self.sections.items, 0..) |sect, n_sect| {
        if (sect.attrs() & macho.S_ATTR_DEBUG != 0) continue;
        if (sect.type() == macho.S_COALESCED and mem.eql(u8, "__eh_frame", sect.sectName())) continue;

        const name = try std.fmt.allocPrintZ(gpa, "{s}${s}", .{ sect.segName(), sect.sectName() });
        defer gpa.free(name);
        const atom_index = try self.addAtom(name, sect.size, sect.@"align", @intCast(n_sect), macho_file);
        const atom = macho_file.getAtom(atom_index).?;
        atom.relocs = try self.parseRelocs(gpa, sect);
        atom.off = 0;
    }
}

fn addAtom(
    self: *Object,
    name: [:0]const u8,
    size: u64,
    alignment: u32,
    n_sect: u8,
    macho_file: *MachO,
) !Atom.Index {
    const gpa = macho_file.base.allocator;
    const atom_index = try macho_file.addAtom();
    const atom = macho_file.getAtom(atom_index).?;
    atom.file = self.index;
    atom.atom_index = atom_index;
    atom.name = try macho_file.string_intern.insert(gpa, name);
    atom.n_sect = n_sect;
    atom.size = size;
    atom.alignment = alignment;
    self.atoms.items[n_sect] = atom_index;
    return atom_index;
}

/// When initializing the symbol table, we need to ensure the symbols are actually
/// sorted so that all locals come before all globals (defined and undefined).
/// If DYSYMTAB load command is present, the symtab is already sorted.
/// Otherwise, we sort the symbols and redo the relocation links.
fn initSymbols(self: *Object, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;

    self.first_global = if (self.getLoadCommand(.DYSYMTAB)) |lc| blk: {
        const cmd = lc.cast(macho.dysymtab_command).?;
        break :blk cmd.ilocalsym + cmd.nlocalsym;
    } else try self.sortSymbols(gpa);

    try self.symbols.ensureUnusedCapacity(gpa, self.symtab.items.len);

    for (self.symtab.items[0..self.first_global], 0..) |local, i| {
        const index = try macho_file.addSymbol();
        self.symbols.appendAssumeCapacity(index);
        const symbol = macho_file.getSymbol(index);
        const name = self.getString(local.n_strx);
        symbol.* = .{
            .value = local.n_value - self.sections.items[local.n_sect - 1].addr,
            .name = try macho_file.string_intern.insert(gpa, name),
            .nlist_idx = @intCast(i),
            .atom = if (local.abs()) 0 else self.atoms.items[local.n_sect - 1],
            .file = self.index,
        };
    }

    for (self.symtab.items[self.first_global..]) |global| {
        const name = self.getString(global.n_strx);
        const off = try macho_file.string_intern.insert(gpa, name);
        const gop = try macho_file.getOrCreateGlobal(off);
        self.symbols.addOneAssumeCapacity().* = gop.index;
    }
}

const SymbolAtIndex = struct {
    index: u32,

    /// Performs lexicographic-like check.
    /// * lhs and rhs defined
    ///   * if lhs == rhs
    ///     * if lhs.n_sect == rhs.n_sect
    ///       * ext < weak < local
    ///     * lhs.n_sect < rhs.n_sect
    ///   * lhs < rhs
    /// * !rhs is undefined
    fn lessThan(ctx: *const Object, lhs_index: SymbolAtIndex, rhs_index: SymbolAtIndex) bool {
        const lhs = ctx.symtab.items[lhs_index.index];
        const rhs = ctx.symtab.items[rhs_index.index];
        if (lhs.sect() and rhs.sect()) {
            if (lhs.n_value == rhs.n_value) {
                if (lhs.n_sect == rhs.n_sect) {
                    return lhs.n_strx < rhs.n_strx;
                } else return lhs.n_sect < rhs.n_sect;
            } else return lhs.n_value < rhs.n_value;
        } else if (lhs.undf() and rhs.undf()) {
            return lhs.n_strx < rhs.n_strx;
        } else return rhs.undf();
    }
};

fn sortSymbols(self: *Object, allocator: Allocator) !Symbol.Index {
    const sym_indexes = try allocator.alloc(SymbolAtIndex, self.symtab.items.len);
    defer allocator.free(sym_indexes);
    const backlinks = try allocator.alloc(u32, self.symtab.items.len);
    defer allocator.free(backlinks);

    for (0..self.symtab.items.len) |i| {
        sym_indexes[i] = .{ .index = @intCast(i) };
    }

    mem.sort(SymbolAtIndex, sym_indexes, self, SymbolAtIndex.lessThan);

    for (sym_indexes, 0..) |index, i| {
        backlinks[index.index] = @intCast(i);
    }

    for (self.relocations.items) |*rel| {
        if (rel.r_extern == 0) continue;
        rel.r_symbolnum = @intCast(backlinks[rel.r_symbolnum]);
    }

    var symtab = try self.symtab.clone(allocator);
    defer symtab.deinit(allocator);
    self.symtab.clearRetainingCapacity();

    for (sym_indexes) |index| {
        self.symtab.appendAssumeCapacity(symtab.items[index.index]);
    }

    const first_global = for (self.symtab.items, 0..) |nlist, i| {
        if (nlist.ext()) break i;
    } else self.symtab.items.len;
    return @intCast(first_global);
}

fn initDataInCode(self: *Object, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    try self.parseDataInCode(gpa);

    if (self.data_in_code.items.len == 0) return;

    var next_dice: usize = 0;

    for (self.atoms.items) |atom_index| {
        const atom = macho_file.getAtom(atom_index) orelse continue;
        if (!atom.flags.alive) continue;
        if (next_dice >= self.data_in_code.items.len) break;
        const off = atom.getInputSection(macho_file).addr + atom.off;

        atom.dice = .{ .pos = next_dice };

        while (next_dice < self.data_in_code.items.len and
            self.data_in_code.items[next_dice].offset >= off) : (next_dice += 1)
        {}

        atom.dice.len = next_dice - atom.dice.pos;
    }
}

/// Parse all relocs for the input section, and sort in ascending order.
/// Previously, I have wrongly assumed the compilers output relocations for each
/// section in a sorted manner which is simply not true.
fn parseRelocs(self: *Object, allocator: Allocator, sect: macho.section_64) !Atom.Loc {
    const relocLessThan = struct {
        fn relocLessThan(ctx: void, lhs: macho.relocation_info, rhs: macho.relocation_info) bool {
            _ = ctx;
            return lhs.r_address < rhs.r_address;
        }
    }.relocLessThan;

    if (sect.nreloc == 0) return .{};
    const pos: u32 = @intCast(self.relocations.items.len);
    const relocs = @as(
        [*]align(1) const macho.relocation_info,
        @ptrCast(self.data.ptr + sect.reloff),
    )[0..sect.nreloc];
    try self.relocations.ensureUnusedCapacity(allocator, relocs.len);
    self.relocations.appendUnalignedSliceAssumeCapacity(relocs);
    mem.sort(macho.relocation_info, self.relocations.items[pos..], {}, relocLessThan);
    return .{ .pos = pos, .len = sect.nreloc };
}

fn parseDataInCode(self: *Object, allocator: Allocator) !void {
    const diceLessThan = struct {
        fn diceLessThan(ctx: void, lhs: macho.data_in_code_entry, rhs: macho.data_in_code_entry) bool {
            _ = ctx;
            return lhs.offset < rhs.offset;
        }
    }.diceLessThan;

    const lc = self.getLoadCommand(.DATA_IN_CODE) orelse return;
    const cmd = lc.cast(macho.linkedit_data_command).?;
    const ndice = @divExact(cmd.datasize, @sizeOf(macho.data_in_code_entry));
    const dice = @as(
        [*]align(1) const macho.data_in_code_entry,
        @ptrCast(self.data.ptr + cmd.dataoff),
    )[0..ndice];
    try self.data_in_code.ensureTotalCapacityPrecise(allocator, dice.len);
    self.data_in_code.appendUnalignedSliceAssumeCapacity(dice);
    mem.sort(macho.data_in_code_entry, self.data_in_code.items, {}, diceLessThan);
}

fn initPlatform(self: *Object) void {
    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    self.platform = while (it.next()) |cmd| {
        switch (cmd.cmd()) {
            .BUILD_VERSION,
            .VERSION_MIN_MACOSX,
            .VERSION_MIN_IPHONEOS,
            .VERSION_MIN_TVOS,
            .VERSION_MIN_WATCHOS,
            => break MachO.Options.Platform.fromLoadCommand(cmd),
            else => {},
        }
    } else null;
}

/// Currently, we only check if a compile unit for this input object file exists
/// and record that so that we can emit symbol stabs.
/// TODO in the future, we want parse debug info and debug line sections so that
/// we can provide nice error locations to the user.
fn initDwarfInfo(self: *Object, allocator: Allocator) !void {
    var debug_info_index: ?usize = null;
    var debug_abbrev_index: ?usize = null;
    var debug_str_index: ?usize = null;

    for (self.sections.items, 0..) |sect, index| {
        if (sect.attrs() & macho.S_ATTR_DEBUG == 0) continue;
        if (mem.eql(u8, sect.sectName(), "__debug_info")) debug_info_index = index;
        if (mem.eql(u8, sect.sectName(), "__debug_abbrev")) debug_abbrev_index = index;
        if (mem.eql(u8, sect.sectName(), "__debug_str")) debug_str_index = index;
    }

    if (debug_info_index == null or debug_abbrev_index == null) return;

    var dwarf_info = DwarfInfo{
        .debug_info = self.getSectionData(@intCast(debug_info_index.?)),
        .debug_abbrev = self.getSectionData(@intCast(debug_abbrev_index.?)),
        .debug_str = if (debug_str_index) |index| self.getSectionData(@intCast(index)) else "",
    };
    dwarf_info.init(allocator) catch return; // TODO flag an error
    self.dwarf_info = dwarf_info;
}

pub fn resolveSymbols(self: *Object, macho_file: *MachO) void {
    for (self.getGlobals(), 0..) |index, i| {
        const nlist_idx = @as(Symbol.Index, @intCast(self.first_global + i));
        const nlist = self.symtab.items[nlist_idx];

        if (nlist.undf() and !nlist.tentative()) continue;
        if (!nlist.tentative() and !nlist.abs()) {
            const atom_index = self.atoms.items[nlist.n_sect - 1];
            const atom = macho_file.getAtom(atom_index) orelse continue;
            if (!atom.flags.alive) continue;
        }

        const global = macho_file.getSymbol(index);
        if (self.asFile().getSymbolRank(nlist, !self.alive) < global.getSymbolRank(macho_file)) {
            var atom: Atom.Index = 0;
            var value = nlist.n_value;
            if (!nlist.tentative() and !nlist.abs()) {
                atom = self.atoms.items[nlist.n_sect - 1];
                value -= self.sections.items[nlist.n_sect - 1].addr;
            }
            global.value = value;
            global.atom = atom;
            global.nlist_idx = nlist_idx;
            global.file = self.index;
            global.flags.weak = nlist.weakDef() or nlist.pext();
        }
    }
}

pub fn markLive(self: *Object, macho_file: *MachO) void {
    for (self.getGlobals(), 0..) |index, i| {
        const nlist_idx = self.first_global + i;
        const nlist = self.symtab.items[nlist_idx];
        if (nlist.weakRef()) continue;

        const global = macho_file.getSymbol(index);
        const file = global.getFile(macho_file) orelse continue;
        const should_keep = nlist.undf() or (nlist.tentative() and global.getNlist(macho_file).tentative());
        if (should_keep and !file.isAlive()) {
            file.setAlive();
            file.markLive(macho_file);
        }
    }
}

pub fn scanRelocs(self: Object, macho_file: *MachO) !void {
    for (self.atoms.items) |atom_index| {
        const atom = macho_file.getAtom(atom_index) orelse continue;
        if (!atom.flags.alive) continue;
        const sect = atom.getInputSection(macho_file);
        if (sect.isZerofill()) continue;
        try atom.scanRelocs(macho_file);
    }

    // TODO scan __eh_frame relocs
}

pub fn convertBoundarySymbols(self: *Object, macho_file: *MachO) !void {
    const parseBoundarySymbol = struct {
        fn parseBoundarySymbol(name: []const u8) ?struct {
            segment: bool,
            start: bool,
            segname: []const u8,
            sectname: []const u8,
        } {
            invalid: {
                var segment: ?bool = null;
                var start: ?bool = null;
                var segname: []const u8 = "";
                var sectname: []const u8 = "";

                var it = std.mem.splitScalar(u8, name, '$');
                var next = it.next() orelse break :invalid;

                if (std.mem.eql(u8, next, "segment")) {
                    segment = true;
                } else if (std.mem.eql(u8, next, "section")) {
                    segment = false;
                }

                if (segment == null) break :invalid;

                next = it.next() orelse break :invalid;

                if (std.mem.eql(u8, next, "start")) {
                    start = true;
                } else if (std.mem.eql(u8, next, "stop")) {
                    start = false;
                }

                if (start == null) break :invalid;

                segname = it.next() orelse break :invalid;
                if (!segment.?) sectname = it.next() orelse break :invalid;

                return .{
                    .segment = segment.?,
                    .start = start.?,
                    .segname = segname,
                    .sectname = sectname,
                };
            }
            return null;
        }
    }.parseBoundarySymbol;

    const gpa = macho_file.base.allocator;

    for (self.getGlobals(), 0..) |index, i| {
        const nlist_idx = @as(Symbol.Index, @intCast(self.first_global + i));
        const nlist = &self.symtab.items[nlist_idx];
        if (!nlist.undf()) continue;

        const global = macho_file.getSymbol(index);
        if (global.getFile(macho_file)) |file| {
            if (file.getIndex() != self.index) continue;
        }

        const name = global.getName(macho_file);
        const parsed = parseBoundarySymbol(name) orelse continue;

        const info: Symbol.BoundaryInfo = .{
            .segment = parsed.segment,
            .start = parsed.start,
        };
        global.flags.boundary = true;
        try global.addExtra(.{ .boundary = @bitCast(info) }, macho_file);

        const atom_index = try macho_file.addAtom();
        try self.atoms.append(gpa, atom_index);

        const atom = macho_file.getAtom(atom_index).?;
        atom.atom_index = atom_index;
        atom.name = try macho_file.string_intern.insert(gpa, name);
        atom.file = self.index;

        const n_sect = try self.addSection(gpa, parsed.segname, parsed.sectname);
        const sect = &self.sections.items[n_sect];
        sect.flags = macho.S_REGULAR;
        atom.n_sect = n_sect;

        global.value = 0;
        global.atom = atom_index;
        global.file = self.index;
        global.flags.weak = false;
        global.nlist_idx = nlist_idx;

        nlist.n_value = 0;
        nlist.n_type = macho.N_PEXT | macho.N_EXT | macho.N_SECT;
        nlist.n_sect = n_sect + 1;
    }
}

pub fn convertTentativeDefinitions(self: *Object, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    for (self.getGlobals(), 0..) |index, i| {
        const nlist_idx = @as(Symbol.Index, @intCast(self.first_global + i));
        const nlist = &self.symtab.items[nlist_idx];
        if (!nlist.tentative()) continue;

        const global = macho_file.getSymbol(index);
        const global_file = global.getFile(macho_file).?;
        if (global_file.getIndex() != self.index) {
            //     if (elf_file.options.warn_common) {
            //         elf_file.base.warn("{}: multiple common symbols: {s}", .{
            //             self.fmtPath(),
            //             global.getName(elf_file),
            //         });
            //     }
            continue;
        }

        const atom_index = try macho_file.addAtom();
        try self.atoms.append(gpa, atom_index);

        const name = try std.fmt.allocPrintZ(gpa, "__DATA$__common${s}", .{global.getName(macho_file)});
        defer gpa.free(name);
        const atom = macho_file.getAtom(atom_index).?;
        atom.atom_index = atom_index;
        atom.name = try macho_file.string_intern.insert(gpa, name);
        atom.file = self.index;
        atom.size = nlist.n_value;
        atom.alignment = (nlist.n_desc >> 8) & 0x0f;

        const n_sect = try self.addSection(gpa, "__DATA", "__common");
        const sect = &self.sections.items[n_sect];
        sect.flags = macho.S_ZEROFILL;
        sect.size = atom.size;
        sect.@"align" = atom.alignment;
        atom.n_sect = n_sect;

        global.value = 0;
        global.atom = atom_index;
        global.flags.weak = false;

        nlist.n_value = 0;
        nlist.n_type = macho.N_EXT | macho.N_SECT;
        nlist.n_sect = n_sect + 1;
        nlist.n_desc = 0;
    }
}

fn addSection(self: *Object, allocator: Allocator, segname: []const u8, sectname: []const u8) !u8 {
    const n_sect = @as(u8, @intCast(self.sections.items.len));
    const sect = try self.sections.addOne(allocator);
    sect.* = .{
        .sectname = MachO.makeStaticString(sectname),
        .segname = MachO.makeStaticString(segname),
    };
    return n_sect;
}

pub fn calcSymtabSize(self: *Object, macho_file: *MachO) !void {
    for (self.getLocals()) |local_index| {
        const local = macho_file.getSymbol(local_index);
        if (local.getAtom(macho_file)) |atom| if (!atom.flags.alive) continue;
        const nlist = local.getNlist(macho_file);
        if (nlist.stab()) continue;
        local.flags.output_symtab = true;
        try local.addExtra(.{ .symtab = self.output_symtab_ctx.nlocals }, macho_file);
        self.output_symtab_ctx.nlocals += 1;
        self.output_symtab_ctx.strsize += @as(u32, @intCast(local.getName(macho_file).len + 1));
    }

    for (self.getGlobals()) |global_index| {
        const global = macho_file.getSymbol(global_index);
        const file_ptr = global.getFile(macho_file) orelse continue;
        if (file_ptr.getIndex() != self.index) continue;
        if (global.getAtom(macho_file)) |atom| if (!atom.flags.alive) continue;
        global.flags.output_symtab = true;
        if (global.isLocal()) {
            try global.addExtra(.{ .symtab = self.output_symtab_ctx.nlocals }, macho_file);
            self.output_symtab_ctx.nlocals += 1;
        } else if (global.flags.@"export") {
            try global.addExtra(.{ .symtab = self.output_symtab_ctx.nexports }, macho_file);
            self.output_symtab_ctx.nexports += 1;
        } else {
            assert(global.flags.import);
            try global.addExtra(.{ .symtab = self.output_symtab_ctx.nimports }, macho_file);
            self.output_symtab_ctx.nimports += 1;
        }
        self.output_symtab_ctx.strsize += @as(u32, @intCast(global.getName(macho_file).len + 1));
    }
}

// pub fn calcStabsSize(self: *Object, macho_file: *MachO) !void {
//     if (!self.hasDebugInfo()) return;

//     self.output_symtab_ctx.nlocals += 4;
//     self.output_symtab_ctx.strsize += @as(u32, @intCast())

//     for (self.getLocals()) |local_index| {
//         const local = macho_file.getSymbol(local_index);
//         if (!local.flags.output_symtab) continue;

//         try local.addExtra(.{ .symtab = self.output_symtab_ctx.nlocals }, macho_file);
//         self.output_symtab_ctx.nlocals += 1;
//         self.output_symtab_ctx.strsize += @as(u32, @intCast(local.getName(macho_file).len + 1));
//     }

//     for (self.getGlobals()) |global_index| {
//         const global = macho_file.getSymbol(global_index);
//         const file_ptr = global.getFile(macho_file) orelse continue;
//         if (file_ptr.getIndex() != self.index) continue;
//         if (global.getAtom(macho_file)) |atom| if (!atom.flags.alive) continue;
//         global.flags.output_symtab = true;
//         if (global.isLocal()) {
//             try global.addExtra(.{ .symtab = self.output_symtab_ctx.nlocals }, macho_file);
//             self.output_symtab_ctx.nlocals += 1;
//         } else if (global.flags.@"export") {
//             try global.addExtra(.{ .symtab = self.output_symtab_ctx.nexports }, macho_file);
//             self.output_symtab_ctx.nexports += 1;
//         } else {
//             assert(global.flags.import);
//             try global.addExtra(.{ .symtab = self.output_symtab_ctx.nimports }, macho_file);
//             self.output_symtab_ctx.nimports += 1;
//         }
//         self.output_symtab_ctx.strsize += @as(u32, @intCast(global.getName(macho_file).len + 1));
//     }

// }

pub fn writeSymtab(self: Object, macho_file: *MachO) void {
    for (self.getLocals()) |local_index| {
        const local = macho_file.getSymbol(local_index);
        const idx = local.getOutputSymtabIndex(macho_file) orelse continue;
        const out_sym = &macho_file.symtab.items[idx];
        out_sym.n_strx = @intCast(macho_file.strtab.items.len);
        macho_file.strtab.appendSliceAssumeCapacity(local.getName(macho_file));
        macho_file.strtab.appendAssumeCapacity(0);
        local.setOutputSym(macho_file, out_sym);
    }

    for (self.getGlobals()) |global_index| {
        const global = macho_file.getSymbol(global_index);
        const file = global.getFile(macho_file) orelse continue;
        if (file.getIndex() != self.index) continue;
        const idx = global.getOutputSymtabIndex(macho_file) orelse continue;
        const n_strx = @as(u32, @intCast(macho_file.strtab.items.len));
        macho_file.strtab.appendSliceAssumeCapacity(global.getName(macho_file));
        macho_file.strtab.appendAssumeCapacity(0);
        const out_sym = &macho_file.symtab.items[idx];
        out_sym.n_strx = n_strx;
        global.setOutputSym(macho_file, out_sym);
    }
}

pub fn claimUnresolved(self: Object, macho_file: *MachO) void {
    for (self.getGlobals(), 0..) |global_index, i| {
        const nlist_idx = @as(Symbol.Index, @intCast(self.first_global + i));
        const nlist = self.symtab.items[nlist_idx];
        if (!nlist.undf()) continue;

        const global = macho_file.getSymbol(global_index);
        if (global.getFile(macho_file)) |_| {
            if (!global.getNlist(macho_file).undf()) continue;
        }

        const is_import = switch (macho_file.options.undefined_treatment) {
            .@"error" => false,
            .warn, .suppress => nlist.weakRef(),
            .dynamic_lookup => true,
        };

        global.value = 0;
        global.atom = 0;
        global.nlist_idx = nlist_idx;
        global.file = self.index;
        global.flags.import = is_import;
    }
}

fn getLoadCommand(self: Object, lc: macho.LC) ?LoadCommandIterator.LoadCommand {
    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    while (it.next()) |cmd| {
        if (cmd.cmd() == lc) return cmd;
    } else return null;
}

fn getSectionData(self: Object, index: u8) []const u8 {
    assert(index < self.sections.items.len);
    const sect = self.sections.items[index];
    return self.data[sect.offset..][0..sect.size];
}

fn getString(self: Object, off: u32) [:0]const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(self.strtab.ptr + off)), 0);
}

/// TODO handle multiple CUs
pub fn hasDebugInfo(self: Object) bool {
    const dw = self.dwarf_info orelse return false;
    return dw.compile_units.items.len > 0;
}

pub fn getSourceFilename(self: Object, allocator: Allocator) !?[]const u8 {
    const dw = self.dwarf_info orelse return null;
    const cu = dw.compile_units.items[0];
    const comp_dir_attr = cu.find(std.dwarf.AT.comp_dir, dw) orelse return null;
    const comp_dir = comp_dir_attr[0].getString(comp_dir_attr[1], cu.header.format, &dw) orelse
        return null;
    const file_name_attr = cu.find(std.dwarf.AT.name, dw) orelse return null;
    const file_name = file_name_attr[0].getString(file_name_attr[1], cu.header.format, &dw) orelse
        return null;
    const out = try std.fs.path.join(allocator, &.{ comp_dir, file_name });
    return out;
}

pub fn getLocals(self: Object) []const Symbol.Index {
    return self.symbols.items[0..self.first_global];
}

pub fn getGlobals(self: Object) []const Symbol.Index {
    return self.symbols.items[self.first_global..];
}

pub fn asFile(self: *Object) File {
    return .{ .object = self };
}

pub fn format(
    self: *Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = self;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format objects directly");
}

const FormatContext = struct {
    object: *Object,
    macho_file: *MachO,
};

pub fn fmtAtoms(self: *Object, macho_file: *MachO) std.fmt.Formatter(formatAtoms) {
    return .{ .data = .{
        .object = self,
        .macho_file = macho_file,
    } };
}

fn formatAtoms(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  atoms\n");
    for (object.atoms.items) |atom_index| {
        const atom = ctx.macho_file.getAtom(atom_index) orelse continue;
        try writer.print("    {}\n", .{atom.fmt(ctx.macho_file)});
    }
}

pub fn fmtSymtab(self: *Object, macho_file: *MachO) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .object = self,
        .macho_file = macho_file,
    } };
}

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  locals\n");
    for (object.getLocals()) |index| {
        const local = ctx.macho_file.getSymbol(index);
        try writer.print("    {}\n", .{local.fmt(ctx.macho_file)});
    }
    try writer.writeAll("  globals\n");
    for (object.getGlobals()) |index| {
        const global = ctx.macho_file.getSymbol(index);
        try writer.print("    {}\n", .{global.fmt(ctx.macho_file)});
    }
}

pub fn fmtPath(self: Object) std.fmt.Formatter(formatPath) {
    return .{ .data = self };
}

fn formatPath(
    object: Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    if (object.archive) |path| {
        try writer.writeAll(path);
        try writer.writeByte('(');
        try writer.writeAll(object.path);
        try writer.writeByte(')');
    } else try writer.writeAll(object.path);
}

const assert = std.debug.assert;
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const trace = @import("../tracy.zig").trace;
const std = @import("std");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const DwarfInfo = @import("DwarfInfo.zig");
const File = @import("file.zig").File;
const LoadCommandIterator = macho.LoadCommandIterator;
const MachO = @import("../MachO.zig");
const Object = @This();
const StringTable = @import("../strtab.zig").StringTable;
const Symbol = @import("Symbol.zig");
