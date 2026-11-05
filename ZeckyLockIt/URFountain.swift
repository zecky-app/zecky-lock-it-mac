//
//  URFountain.swift
//  Zecky Lock it (Mac) — Seal it / Keystone air-gapped signing
//
//  UR multipart ("fountain") coding and Bytewords, vendored from
//  Blockchain Commons URKit 15.1.0 (https://github.com/BlockchainCommons/URKit):
//  Utils.swift (CRC32), Bytewords.swift, Fountain/*.swift.
//  Changes: the fountain part header uses ZCBOR instead of DCBOR, and
//  everything is internal, so the app needs no package dependency for this.
//
//  Copyright © Blockchain Commons, LLC.
//  BSD-2-Clause Plus Patent License (SPDX: BSD-2-Clause-Patent).
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//  Subject to the terms and conditions of this license, each copyright holder
//  and contributor hereby grants to those receiving rights under this license a
//  perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable
//  patent license. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
//  CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
//

import CryptoKit
import Foundation

// MARK: - Utils.swift

func toHex(byte: UInt8) -> String {
    String(format: "%02x", byte)
}

func toHex(data: Data) -> String {
    data.reduce(into: "") {
        $0 += toHex(byte: $1)
    }
}

extension Data {
    var hex: String {
        toHex(data: self)
    }
}

func toByte<S>(hex: S) -> UInt8? where S: StringProtocol {
    guard hex.count == 2 else {
        return nil
    }
    return UInt8(hex, radix: 16)
}

func toData<S>(hex: S) -> Data? where S: StringProtocol {
    guard hex.count & 1 == 0 else {
        return nil
    }
    let len = hex.count / 2
    var result = Data(capacity: len)
    for i in 0..<len {
        let j = hex.index(hex.startIndex, offsetBy: i*2)
        let k = hex.index(j, offsetBy: 2)
        let hexByte = hex[j..<k]
        if var num = toByte(hex: hexByte) {
            result.append(&num, count: 1)
        } else {
            return nil
        }
    }
    return result
}

extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var chunk = ""
        for c in self {
            chunk.append(c)
            if chunk.count == size {
                result.append(chunk)
                chunk = ""
            }
        }
        if !chunk.isEmpty {
            result.append(chunk)
        }
        return result
    }
    
    var utf8Data: Data {
        data(using: .utf8)!
    }
}

// Based on: https://gist.github.com/01GOD/3e6bb0b19a0caf138dd4b57e22122ae1
enum CRC32 {
    static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            (0..<8).reduce(UInt32(i), { c, _ in
                (c % 2 == 0) ? (c >> 1) : (0xEDB88320 ^ (c >> 1))
            })
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        ~(data.reduce(~UInt32(0), { crc, byte in
            (crc >> 8) ^ table[(Int(crc) ^ Int(byte)) & 0xFF]
        }))
    }

    static func checksum(_ string: String) -> UInt32 {
        checksum(string.utf8Data)
    }
}

// MARK: - Bytewords.swift

enum BytewordsDecodingError: LocalizedError {
    case invalidWord
    case invalidChecksum
    
    var errorDescription: String? {
        switch self {
        case .invalidWord:
            return "Invalid Bytewords word."
        case .invalidChecksum:
            return "Invalid Bytewords checksum."
        }
    }
}

struct Bytewords {
    enum Style {
        case standard
        case uri
        case minimal
    }
    
    static func identifier(_ data: Data) -> String {
        precondition(data.count == 4, "Bytewords identifiers have exactly 4 bytes long")
        return encodeRaw(data, separator: " ")
    }

    static func encodedLength(_ len: Int, style: Style = .standard) -> Int {
        switch style {
        case .standard, .uri:
            return len * 4 + (len - 1)
        case .minimal:
            return len * 2
        }
    }

    static func encode(_ data: Data, style: Style = .standard) -> String {
        switch style {
        case .standard:
            return encode(data, separator: " ")
        case .uri:
            return encode(data, separator: "-")
        case .minimal:
            return encodeMinimal(data)
        }
    }
    
    static func checksumWords(_ data: Data, style: Style = .standard) -> String {
        let checksum = Self.checksum(of: data)
        return switch style {
        case .standard:
            encodeRaw(checksum, separator: " ")
        case .uri:
            encodeRaw(checksum, separator: "-")
        case .minimal:
            encodeMinimalRaw(checksum)
        }
    }

    static func decode(_ string: String, style: Style = .standard) throws -> Data {
        switch style {
        case .standard:
            return try decode(string, separator: " ")
        case .uri:
            return try decode(string, separator: "-")
        case .minimal:
            return try decodeMinimal(string)
        }
    }
    
    private static func encodeRaw(_ data: Data, separator: String) -> String {
        let words = data.map { byte in
            indexToBytewords[byte]!
        }
        return words.joined(separator: separator)
    }

    private static func encode(_ data: Data, separator: String) -> String {
        encodeRaw(data + checksum(of: data), separator: separator)
    }
    
    private static func encodeMinimalRaw(_ data: Data) -> String {
        let words = data.map { byte in
            indexToMinimalBytewords[byte]!
        }
        return words.joined(separator: "")
    }

    private static func encodeMinimal(_ data: Data) -> String {
        encodeMinimalRaw(data + checksum(of: data))
    }

    private static func decode(_ string: String, separator: Character) throws -> Data {
        let words = string.split(separator: separator)
        let values = try words.map { word -> UInt8 in
            guard let value = bytewordsToIndex[String(word)] else {
                throw BytewordsDecodingError.invalidWord
            }
            return value
        }
        let data = Data(values)
        return try stripChecksum(from: data)
    }

    private static func decodeMinimal(_ string: String) throws -> Data {
        let words = string.chunked(into: 2)
        let values = try words.map { word -> UInt8 in
            guard let value = minimalBytewordsToIndex[word] else {
                throw BytewordsDecodingError.invalidWord
            }
            return value
        }
        let data = Data(values)
        return try stripChecksum(from: data)
    }

    private static let bytewords = """
    ableacidalsoapexaquaarchatomauntawayaxisbackbaldbarnbeltbetabias\
    bluebodybragbrewbulbbuzzcalmcashcatschefcityclawcodecolacookcost\
    cruxcurlcuspcyandarkdatadaysdelidicedietdoordowndrawdropdrumdull\
    dutyeacheasyechoedgeepicevenexamexiteyesfactfairfernfigsfilmfish\
    fizzflapflewfluxfoxyfreefrogfuelfundgalagamegeargemsgiftgirlglow\
    goodgraygrimgurugushgyrohalfhanghardhawkheathelphighhillholyhope\
    hornhutsicedideaidleinchinkyintoirisironitemjadejazzjoinjoltjowl\
    judojugsjumpjunkjurykeepkenokeptkeyskickkilnkingkitekiwiknoblamb\
    lavalazyleaflegsliarlimplionlistlogoloudloveluaulucklungmainmany\
    mathmazememomenumeowmildmintmissmonknailnavyneednewsnextnoonnote\
    numbobeyoboeomitonyxopenovalowlspaidpartpeckplaypluspoempoolpose\
    puffpumapurrquadquizraceramprealredorichroadrockroofrubyruinruns\
    rustsafesagascarsetssilkskewslotsoapsolosongstubsurfswantacotask\
    taxitenttiedtimetinytoiltombtoystriptunatwinuglyundouniturgeuser\
    vastveryvetovialvibeviewvisavoidvowswallwandwarmwaspwavewaxywebs\
    whatwhenwhizwolfworkyankyawnyellyogayurtzapszerozestzinczonezoom
    """

    private static let indexToBytewords: [UInt8 : String] = {
        var result: [UInt8 : String] = [:]
        var a = bytewords.makeIterator()
        (0...255).forEach { i in
            let word = String((1...4).map { _ in a.next()! })
            result[UInt8(i)] = word
        }
        return result
    }()

    static let allWords: [String] = {
        var result: [String] = .init()
        result.reserveCapacity(256)
        var a = bytewords.makeIterator()
        (0...255).forEach { i in
            let word = String((1...4).map { _ in a.next()! })
            result.append(word)
        }
        return result
    }()

    private static let indexToMinimalBytewords: [UInt8 : String] = {
        var result: [UInt8 : String] = [:]
        var a = bytewords.makeIterator()
        (0...255).forEach { i in
            let letters = (1...4).map { _ in a.next()! }
            let word = String([letters[0], letters[3]])
            result[UInt8(i)] = word
        }
        return result
    }()

    private static let bytewordsToIndex: [String : UInt8] = {
        var result: [String: UInt8] = [:]
        var a = bytewords.makeIterator()
        (0...255).forEach { i in
            let word = String((1...4).map { _ in a.next()! })
            result[word] = UInt8(i)
        }
        return result
    }()

    private static let minimalBytewordsToIndex: [String: UInt8] = {
        var result: [String: UInt8] = [:]
        var a = bytewords.makeIterator()
        (0...255).forEach { i in
            let letters = (1...4).map { _ in a.next()! }
            let word = String([letters[0], letters[3]])
            result[word] = UInt8(i)
        }
        return result
    }()
    
    static func checksum(of data: Data) -> Data {
        CRC32.checksum(data).serialized
    }

    private static func stripChecksum(from data: Data) throws -> Data {
        let checksumSize = MemoryLayout<UInt32>.size
        guard data.count > checksumSize else { throw BytewordsDecodingError.invalidChecksum }
        let message = data.prefix(data.count - checksumSize)
        let checksum = CRC32.checksum(message)
        let messageChecksum = deserialize(UInt32.self, Data(data.suffix(checksumSize)))
        guard messageChecksum == checksum else { throw BytewordsDecodingError.invalidChecksum }
        return message
    }
}

protocol Serializable {
    var serialized: Data { get }
}

func serialize<I>(_ n: I, littleEndian: Bool = false) -> Data where I: FixedWidthInteger {
    let count = MemoryLayout<I>.size
    var d = Data(repeating: 0, count: count)
    d.withUnsafeMutableBytes {
        $0.bindMemory(to: I.self).baseAddress!.pointee = littleEndian ? n.littleEndian : n.bigEndian
    }
    return d
}

func deserialize<T, D>(_ t: T.Type, _ data: D, littleEndian: Bool = false) -> T? where T: FixedWidthInteger, D : DataProtocol {
    let size = MemoryLayout<T>.size
    guard data.count >= size else {
        return nil
    }

    var dataBytes = [UInt8](repeating: 0, count: size)
    return dataBytes.withUnsafeMutableBytes {
        data.copyBytes(to: $0, count: size)
        let a = $0.bindMemory(to: T.self).baseAddress!.pointee
        return littleEndian ? T(littleEndian: a) : T(bigEndian: a)
    }
}

extension FixedWidthInteger {
    func serialized(littleEndian: Bool = false) -> Data {
        serialize(self, littleEndian: littleEndian)
    }
}

extension UInt: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension UInt8: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension UInt16: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension UInt32: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension UInt64: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension Int: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension Int8: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension Int16: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension Int32: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

extension Int64: Serializable {
    var serialized: Data {
        serialize(self)
    }
}

// MARK: - Fountain/FountainUtils.swift

extension Data {
    func xor(into data: inout Data) {
        assert(count == data.count)
        withUnsafeBytes { selfBytes -> Void in
            let selfBytes = selfBytes.bindMemory(to: UInt8.self)
            return data.withUnsafeMutableBytes { dBytes in
                let dBytes = dBytes.bindMemory(to: UInt8.self)
                for i in (0..<count) {
                    dBytes[i] ^= selfBytes[i]
                }
            }
        }
    }

    func xor(with data: Data) -> Data {
        var b = self
        data.xor(into: &b)
        return b
    }
}

final class DegreeChooser {
    let seqLen: Int
    let degreeProbabilities: [Double]
    let sampler: RandomSampler
    
    init(seqLen: Int) {
        self.seqLen = seqLen
        self.degreeProbabilities = (1 ... seqLen).map { 1 / Double($0) }
        self.sampler = RandomSampler(degreeProbabilities)
    }
    
    func chooseDegree(using rng: Xoshiro256) -> Int {
        return sampler.next(rng.nextDouble) + 1
    }
}

final class FragmentChooser {
    let degreeChooser: DegreeChooser
    let indexes: [Int]
    let checksum: UInt32
    
    var seqLen: Int { indexes.count }
    
    init(seqLen: Int, checksum: UInt32) {
        self.degreeChooser = DegreeChooser(seqLen: seqLen)
        self.indexes = Array(0 ..< seqLen)
        self.checksum = checksum
    }
    
    func chooseFragments(at seqNum: UInt32) -> FragmentIndexes {
        // The first `seqLen` parts are the "simple" fragments, not mixed with any
        // others. This means that if you only generate the first `seqLen` parts,
        // then you have all the fragments you need to decode the message.
        if seqNum <= seqLen {
            return Set([Int(seqNum) - 1])
        } else {
            let seed = Data([seqNum.serialized, checksum.serialized].joined())
            let rng = Xoshiro256(seed: seed)
            let degree = degreeChooser.chooseDegree(using: rng)
            return Set(shuffled(indexes, rng: rng, count: degree))
        }
    }
}

// Fisher-Yates shuffle
func shuffled<T>(_ items: [T], rng: Xoshiro256, count: Int) -> [T] {
    var remaining = items
    var result: [T] = []
    result.reserveCapacity(remaining.count)
    while result.count != count {
        let index = rng.nextInt(in: 0 ..< remaining.count)
        let item = remaining.remove(at: index)
        result.append(item)
    }
    return result
}

// MARK: - Fountain/RandomSampler.swift

final class RandomSampler {
    private let probs: [Double]
    private let aliases: [Int]

    init(_ probs: [Double]) {
        probs.forEach { precondition($0 >= 0) }

        // Normalize given probabilities
        let sum = probs.reduce(0, +)
        precondition(sum > 0)

        let n = probs.count
        var P = probs.map { $0 * Double(n) / sum }

        var S: [Int] = []
        var L: [Int] = []

        // Set separate index lists for small and large probabilities:
        for i in (0 ... n-1).reversed() {
            // at variance from Schwarz, we reverse the index order
            if P[i] < 1 {
                S.append(i)
            } else {
                L.append(i)
            }
        }

        // Work through index lists
        var probs = [Double](repeating: 0, count: n)
        var aliases = [Int](repeating: 0, count: n)
        while !S.isEmpty && !L.isEmpty {
            let a = S.removeLast() // Schwarz's l
            let g = L.removeLast() // Schwarz's g
            probs[a] = P[a]
            aliases[a] = g
            P[g] += P[a] - 1
            if P[g] < 1 {
                S.append(g)
            } else {
                L.append(g)
            }
        }

        while !L.isEmpty {
            probs[L.removeLast()] = 1
        }

        while !S.isEmpty {
            // can only happen through numeric instability
            probs[S.removeLast()] = 1
        }

        self.probs = probs
        self.aliases = aliases
    }

    func next(_ rng: () -> Double) -> Int {
        let r1 = rng()
        let r2 = rng()
        let n = probs.count
        let i = Int(Double(n) * r1)
        return r2 < probs[i] ? i : aliases[i]
    }

    func next<G: RandomNumberGenerator>(using generator: inout G) -> Int {
        next { Double.random(in: 0...1, using: &generator ) }
    }

    func next() -> Int {
        var g = SystemRandomNumberGenerator()
        return next(using: &g)
    }
}

// MARK: - Fountain/Xoshiro256.swift

/*  Written in 2018 by David Blackman and Sebastiano Vigna (vigna@acm.org)

To the extent possible under law, the author has dedicated all copyright
and related and neighboring rights to this software to the domain
worldwide. This software is distributed without any warranty.

See <http://creativecommons.org/publicdomain/zero/1.0/>. */

/* This is xoshiro256** 1.0, one of our all-purpose, rock-solid
   generators. It has excellent (sub-ns) speed, a state (256 bits) that is
   large enough for any parallel application, and it passes all tests we
   are aware of.

   For generating just floating-point numbers, xoshiro256+ is even faster.

   The state must be seeded so that it is not everywhere zero. If you have
   a 64-bit seed, we suggest to seed a splitmix64 generator and use its
   output to fill s. */
final class Xoshiro256 : RandomNumberGenerator {
    var state: [UInt64]

    init(state: [UInt64]) {
        assert(state.count == 4)
        self.state = state
    }

    convenience init(digest: SHA256Digest) {
        var s = [UInt64](repeating: 0, count: 4)
        digest.withUnsafeBytes { p in
            for i in 0 ..< 4 {
                let o = i * 8
                var v: UInt64 = 0
                for n in 0 ..< 8 {
                    v <<= 8
                    v |= UInt64(p[o + n])
                }
                s[i] = v
            }
        }
        self.init(state: s)
    }

    convenience init(seed: Data) {
        self.init(digest: SHA256.hash(data: seed))
    }

    convenience init(string: String) {
        self.init(seed: string.utf8Data)
    }

    convenience init(crc32: UInt32) {
        self.init(seed: crc32.serialized)
    }

    func next() -> UInt64 {
        func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
            (x << k) | (x >> (64 - k))
        }

        let result = rotl(state[1] &* 5, 7) &* 9
        let t = state[1] << 17

        state[2] ^= state[0]
        state[3] ^= state[1]
        state[1] ^= state[2]
        state[0] ^= state[3]

        state[2] ^= t

        state[3] = rotl(state[3], 45)

        return result
    }

    func nextDouble() -> Double {
        Double(next()) / (Double(UInt64.max) + 1)
    }

    func nextInt(in range: Range<Int>) -> Int {
        Int(nextDouble() * Double(range.count)) + range.lowerBound
    }

    func nextInt(in range: ClosedRange<Int>) -> Int {
        Int(nextDouble() * Double(range.count)) + range.lowerBound
    }

    func nextByte() -> UInt8 {
        UInt8(nextInt(in: 0 ... 255))
    }

    func nextData(count: Int) -> Data {
        let bytes = (0 ..< count).map { _ in nextByte() }
        return Data(bytes)
    }

    /* This is the jump function for the generator. It is equivalent
       to 2^128 calls to next() it can be used to generate 2^128
       non-overlapping subsequences for parallel computations. */
    func jump() {
        let JUMP: [UInt64] = [ 0x180ec6d33cfd0aba, 0xd5a61266f0c9392c, 0xa9582618e03fc9aa, 0x39abdc4529b1661c ]

        var s0: UInt64 = 0
        var s1: UInt64 = 0
        var s2: UInt64 = 0
        var s3: UInt64 = 0

        for j in JUMP {
            for b in 0 ..< 64 {
                if (j & (1 << b)) != 0 {
                    s0 ^= state[0]
                    s1 ^= state[1]
                    s2 ^= state[2]
                    s3 ^= state[3]
                }
                _ = next()
            }
        }

        state[0] = s0
        state[1] = s1
        state[2] = s2
        state[3] = s3
    }

    /* This is the long-jump function for the generator. It is equivalent to
       2^192 calls to next() it can be used to generate 2^64 starting points,
       from each of which jump() will generate 2^64 non-overlapping
       subsequences for parallel distributed computations. */
    func longJump() {
        let LONG_JUMP: [UInt64] = [ 0x76e15d3efefdcbbf, 0xc5004e441c522fb3, 0x77710069854ee241, 0x39109bb02acbe635 ]

        var s0: UInt64 = 0
        var s1: UInt64 = 0
        var s2: UInt64 = 0
        var s3: UInt64 = 0

        for j in LONG_JUMP {
            for b in 0 ..< 64 {
                if (j & (1 << b)) != 0 {
                    s0 ^= state[0]
                    s1 ^= state[1]
                    s2 ^= state[2]
                    s3 ^= state[3]
                }
                _ = next()
            }
        }

        state[0] = s0
        state[1] = s1
        state[2] = s2
        state[3] = s3
    }
}

// MARK: - Fountain/FountainEncoder.swift

enum FountainEncoderError: LocalizedError {
    case invalidPartHeader
    
    var errorDescription: String? {
        switch self {
        case .invalidPartHeader:
            return "FountainEncoder: Invalid part header."
        }
    }
}

final class FountainEncoder {
    let messageLen: Int
    let fragmentLen: Int
    let maxFragmentLen: Int
    var seqNum: UInt32
    var seqLen: Int { fragments.count }
    private(set) var lastFragmentIndexes: FragmentIndexes!

    let checksum: UInt32
    let fragments: [Data]
    let fragmentChooser: FragmentChooser

    /// This becomes `true` when the minimum number of parts
    /// to relay the complete message have been generated
    var isComplete: Bool { seqNum >= seqLen }

    /// True if only a single part will be generated.
    var isSinglePart: Bool { seqLen == 1 }
    
    /// Returns value `<=` 1.0 if single part, `>` 1.0 if multi-part.
    var messagePercentOfMaxFragmentLen: Double {
        Double(maxFragmentLen) / Double(messageLen)
    }

    struct Part: CustomStringConvertible, Codable {
        let seqNum: UInt32
        let seqLen: Int
        let messageLen: Int
        let checksum: UInt32
        let data: Data

        init(seqNum: UInt32, seqLen: Int, messageLen: Int, checksum: UInt32, data: Data) {
            self.seqNum = seqNum
            self.seqLen = seqLen
            self.messageLen = messageLen
            self.checksum = checksum
            self.data = data
        }

        init(cbor: Data) throws {
            guard let decoded = try? ZCBORReader.decode(cbor),
                  let a = decoded.arrayValue, a.count == 5,
                  let seqNum = a[0].uintValue, let seqLen = a[1].uintValue,
                  let messageLen = a[2].uintValue, let checksum = a[3].uintValue,
                  let data = a[4].bytesValue,
                  seqNum <= UInt64(UInt32.max), checksum <= UInt64(UInt32.max),
                  seqLen <= UInt64(Int.max), messageLen <= UInt64(Int.max)
            else { throw FountainEncoderError.invalidPartHeader }
            self.init(seqNum: UInt32(seqNum), seqLen: Int(seqLen), messageLen: Int(messageLen),
                      checksum: UInt32(checksum), data: data)
        }

        var description: String {
            "seqNum:\(seqNum), seqLen:\(seqLen), messageLen:\(messageLen), checksum:\(checksum), data:\(data.hex)"
        }

        var cbor: Data {
            var d = ZCBORWriter.head(major: 4, 5)
            d.append(ZCBORWriter.head(major: 0, UInt64(seqNum)))
            d.append(ZCBORWriter.head(major: 0, UInt64(seqLen)))
            d.append(ZCBORWriter.head(major: 0, UInt64(messageLen)))
            d.append(ZCBORWriter.head(major: 0, UInt64(checksum)))
            d.append(ZCBORWriter.head(major: 2, UInt64(data.count)))
            d.append(data)
            return d
        }
    }

    init(message: Data, maxFragmentLen: Int? = nil, firstSeqNum: UInt32 = 0, minFragmentLen: Int = 10) {
        assert(message.count <= UInt32.max)
        self.messageLen = message.count
        self.checksum = CRC32.checksum(message)
        self.maxFragmentLen = maxFragmentLen ?? message.count
        self.fragmentLen = Self.findNominalFragmentLength(messageLen: message.count, minFragmentLen: minFragmentLen, maxFragmentLen: self.maxFragmentLen)
        self.fragments = Self.partitionMessage(message, fragmentLen: fragmentLen)
        self.seqNum = firstSeqNum
        fragmentChooser = FragmentChooser(seqLen: fragments.count, checksum: checksum)
    }

    func nextPart() -> Part {
        // wrap at period 2^32
        seqNum &+= 1
        // Don't call more than once on single-part generations.
        assert(seqLen > 1 || seqNum == 1)
        // Choose the fragments, and let the caller interrogate which fragments were chosen for debugging or feedback
        lastFragmentIndexes = fragmentChooser.chooseFragments(at: seqNum)
        // Mix the fragments
        let mixed = mix(fragmentIndexes: lastFragmentIndexes)
        // Return the resulting part
        return Part(seqNum: seqNum, seqLen: seqLen, messageLen: messageLen, checksum: checksum, data: mixed)
    }

    private func mix(fragmentIndexes: FragmentIndexes) -> Data {
        if fragmentIndexes.count == 1 {
            // Trivially return a single fragment
            return fragments[fragmentIndexes.first!]
        } else {
            // XOR all the requested fragments together
            return fragmentIndexes.reduce(into: Data(repeating: 0, count: fragmentLen)) { result, index in
                fragments[index].xor(into: &result)
            }
        }
    }

    static func partitionMessage(_ message: Data, fragmentLen: Int) -> [Data] {
        var remaining = message
        var fragments: [Data] = []
        while !remaining.isEmpty {
            var fragment = remaining.prefix(fragmentLen)
            remaining.removeFirst(fragment.count)
            let padding = fragmentLen - fragment.count
            if padding > 0 {
                fragment.append(Data(repeating: 0, count: padding))
            }
            fragments.append(fragment)
        }
        return fragments
    }

    static func findNominalFragmentLength(messageLen: Int, minFragmentLen: Int, maxFragmentLen: Int) -> Int {
        precondition(messageLen > 0)
        precondition(minFragmentLen > 0)
        precondition(maxFragmentLen >= minFragmentLen)
        let maxFragmentCount = messageLen / minFragmentLen
        var fragmentLen: Int!
        for fragmentCount in 1 ... maxFragmentCount {
            fragmentLen = Int(ceil(Double(messageLen) / Double(fragmentCount)))
            if fragmentLen <= maxFragmentLen {
                break
            }
        }
        return fragmentLen
    }
}

// MARK: - Fountain/FountainDecoder.swift

typealias FragmentIndexes = Set<Int>

enum FountainDecoderError: LocalizedError {
    case invalidChecksum
    
    var errorDescription: String? {
        switch self {
        case .invalidChecksum:
            return "FountainDecoder: Invalid checksum."
        }
    }
}

final class FountainDecoder {
    typealias PartDict = [FragmentIndexes: Part]

    var expectedFragmentCount: Int! { return expectedFragmentIndexes?.count }
    private(set) var receivedFragmentIndexes: FragmentIndexes = []
    private(set) var lastFragmentIndexes: FragmentIndexes!
    private(set) var processedPartsCount = 0
    private(set) var result: Result<Data, Error>?

    var expectedFragmentIndexes: FragmentIndexes!
    var expectedFragmentLen: Int!
    var expectedMessageLen: Int!
    var expectedChecksum: UInt32!

    var simpleParts: PartDict = [:]
    var mixedParts: PartDict = [:]
    var queuedParts: [Part] = []
    
    private var fragmentChooser: FragmentChooser!

    var estimatedPercentComplete: Double {
        guard result == nil else { return 1 }
        guard let expectedPartCount = expectedFragmentCount else { return 0 }
        let estimatedInputParts = Double(expectedPartCount) * 1.75
        return min(0.99, Double(processedPartsCount) / estimatedInputParts)
    }

    struct Part {
        let fragmentIndexes: FragmentIndexes
        let data: Data

        // Only used for simple parts
        var index: Int { fragmentIndexes.first! }

        init(_ p: FountainEncoder.Part, fragmentIndexes: FragmentIndexes) {
            self.data = p.data
            self.fragmentIndexes = fragmentIndexes
        }

        init(fragmentIndexes: FragmentIndexes, data: Data) {
            self.fragmentIndexes = fragmentIndexes
            self.data = data
        }

        var isSimple: Bool {
            fragmentIndexes.count == 1
        }
    }

    init() {
    }

    func receivePart(_ encoderPart: FountainEncoder.Part) -> Bool {
        // Don't process the part if we're already done
        guard result == nil else { return false }

        // Don't continue if this part doesn't validate
        guard validatePart(encoderPart) else { return false }

        if fragmentChooser == nil {
            self.fragmentChooser = FragmentChooser(seqLen: encoderPart.seqLen, checksum: encoderPart.checksum)
        }

        // Add this part to the queue
        let fragmentIndexes = fragmentChooser.chooseFragments(at: encoderPart.seqNum)
        let part = Part(encoderPart, fragmentIndexes: fragmentIndexes)
        lastFragmentIndexes = part.fragmentIndexes
        enqueue(part)

        // Process the queue until we're done or the queue is empty
        processQueue()

        // Keep track of how many parts we've processed
        processedPartsCount += 1
        //printPartEnd()
        return true
    }

    private func enqueue(_ part: Part) {
        queuedParts.append(part)
    }

    func printPartEnd() {
        let parts = expectedFragmentCount != nil ? String(expectedFragmentCount) : "nil"
        let percent = Int((estimatedPercentComplete * 100).rounded())
        print("processed: \(processedPartsCount), expected: \(parts), received: \(receivedFragmentIndexes.count), percent: \(percent)%")
    }

    func printPart(_ part: Part) {
        let indexes = Array(part.fragmentIndexes).sorted()
        print("part indexes: \(indexes)")
    }

    private func resultDescription() -> String {
        let desc: String
        switch result {
        case nil:
            desc = "nil"
        case let .success(message)?:
            desc = "\(message.count) bytes"
        case let .failure(error)?:
            desc = error.localizedDescription
        }
        return desc
    }

    func printState() {
        let parts = expectedFragmentCount != nil ? String(expectedFragmentCount) : "nil"
        let received = Array(receivedFragmentIndexes).sorted()
        let mixed = mixedParts.keys.map( { Array($0).sorted() } ).sorted(by: { $0.lexicographicallyPrecedes($1) } )
        let queued = queuedParts.count
        print("parts: \(parts), received: \(received), mixed: \(mixed), queued: \(queued), result: \(resultDescription())")
    }

    private func processQueue() {
        // Process the queue until we're done or the queue is empty
        while result == nil && !queuedParts.isEmpty {
            let part = queuedParts.removeFirst()
            //printPart(part)
            if part.isSimple {
                processSimplePart(part)
            } else {
                processMixedPart(part)
            }
            //printState()
        }
    }

    private func reduceMixed(by part: Part) {
        // Reduce all the current mixed parts by the given part
        let reducedParts = mixedParts.values.map {
            reducePart($0, by: part)
        }

        // Collect all the remaining mixed parts
        var newMixed: PartDict = [:]
        reducedParts.forEach { reducedPart in
            // If this reduced part is now simple
            if reducedPart.isSimple {
                // Add it to the queue
                enqueue(reducedPart)
            } else {
                // Otherwise, add it to the list of current mixed parts
                newMixed[reducedPart.fragmentIndexes] = reducedPart
            }
        }
        mixedParts = newMixed
    }

    // Reduce part `a` by part `b`
    private func reducePart(_ a: Part, by b: Part) -> Part {
        // If the fragments mixed into `b` are a strict (proper) subset of those in `a`...
        if b.fragmentIndexes.isStrictSubset(of: a.fragmentIndexes) {
            // The new fragments in the revised part are `a` - `b`.
            let newIndexes = a.fragmentIndexes.subtracting(b.fragmentIndexes)
            // The new data in the revised part are `a` XOR `b`
            let newData = a.data.xor(with: b.data)
            return Part(fragmentIndexes: newIndexes, data: newData)
        } else {
            // `a` is not reducible by `b`, so return a
            return a
        }
    }

    private func processSimplePart(_ part: Part) {
        // Don't process duplicate parts
        let fragmentIndex = part.index
        guard !receivedFragmentIndexes.contains(fragmentIndex) else { return }

        // Record this part
        simpleParts[part.fragmentIndexes] = part
        receivedFragmentIndexes.insert(fragmentIndex)

        // If we've received all the parts
        if receivedFragmentIndexes == expectedFragmentIndexes {
            // Reassemble the message from its fragments
            let sortedParts = Array(simpleParts.values).sorted { $0.index < $1.index }
            let fragments = sortedParts.map { $0.data }
            let message = Self.joinFragments(fragments, messageLen: expectedMessageLen)

            // Verify the message checksum and note success or failure
            let checksum = CRC32.checksum(message)
            if checksum == expectedChecksum {
                result = .success(message)
            } else {
                result = .failure(FountainDecoderError.invalidChecksum)
            }
        } else {
            // Reduce all the mixed parts by this part
            reduceMixed(by: part)
        }
    }

    private func processMixedPart(_ part: Part) {
        // Don't process duplicate parts
        guard !mixedParts.keys.contains(part.fragmentIndexes) else { return }

        // Reduce this part by all the others
        let p = [simpleParts.values, mixedParts.values].joined().reduce(part) {
            reducePart($0, by: $1)
        }

        // If the part is now simple
        if p.isSimple {
            // Add it to the queue
            enqueue(p)
        } else {
            // Reduce all the mixed parts by this one
            reduceMixed(by: p)
            // Record this new mixed part
            mixedParts[p.fragmentIndexes] = p
        }
    }

    private func validatePart(_ part: FountainEncoder.Part) -> Bool {
        // If this is the first part we've seen
        if expectedFragmentIndexes == nil {
            // Record the things that all the other parts we see will have to match to be valid.
            expectedFragmentIndexes = Set(0 ..< part.seqLen)
            expectedMessageLen = part.messageLen
            expectedChecksum = part.checksum
            expectedFragmentLen = part.data.count
        } else {
            // If this part's values don't match the first part's values
            guard expectedFragmentCount == part.seqLen,
                  expectedMessageLen == part.messageLen,
                  expectedChecksum == part.checksum,
                  expectedFragmentLen == part.data.count
            else {
                // Throw away the part
                return false
            }
        }
        // This part should be processed
        return true
    }

    // Join all the fragments of a message together, throwing away any padding
    static func joinFragments(_ fragments: [Data], messageLen: Int) -> Data {
        var message = Data(fragments.joined())
        let padding = message.count - messageLen
        message.removeLast(padding)
        return message
    }
}
