import Testing
@testable import Database

/// Iterator-model operator tests.

@Suite(.serialized)
struct OperatorsSuite {

    // MARK: - Test source operator

    /// A tuple source backed by an in-memory list of integer/string columns.
    /// Registers are allocated once in `open()`, then mutated in place on
    /// every `next()`.
    final class TestSource: Operator {
        enum Column { case int64, char16 }
        var opened = false
        var closed = false

        private let rows: [[ColumnValue]]
        private let layout: [Column]
        private var index = 0
        private var outputRegs: [Register] = []

        enum ColumnValue {
            case int(Int64)
            case string(String)
        }

        init(layout: [Column], rows: [[ColumnValue]]) {
            self.layout = layout
            self.rows = rows
        }

        func open() {
            outputRegs = layout.map { _ in Register() }
            opened = true
        }

        func next() -> Bool {
            guard index < rows.count else { return false }
            let row = rows[index]
            for (i, value) in row.enumerated() {
                switch value {
                case .int(let v): outputRegs[i].setInt(v)
                case .string(let s): outputRegs[i].setString(s)
                }
            }
            index += 1
            return true
        }

        func close() {
            outputRegs.removeAll()
            closed = true
        }

        func getOutput() -> [Register] { outputRegs }
    }

    // MARK: - Fixtures

    private static let relationStudents: [[TestSource.ColumnValue]] = [
        [.int(24002), .string("Xenokrates      ")],
        [.int(26120), .string("Fichte          ")],
        [.int(29555), .string("Feuerbach       ")],
    ]
    private static let studentsLayout: [TestSource.Column] = [.int64, .char16]

    private static let relationGrades: [[TestSource.ColumnValue]] = [
        [.int(24002), .int(5001), .int(1)],
        [.int(24002), .int(5041), .int(2)],
        [.int(29555), .int(4630), .int(2)],
    ]
    private static let gradesLayout: [TestSource.Column] = [.int64, .int64, .int64]

    private static let relationSetA: [[TestSource.ColumnValue]] = [
        [.int(1)], [.int(1)], [.int(2)], [.int(3)], [.int(3)], [.int(3)],
    ]
    private static let relationSetB: [[TestSource.ColumnValue]] = [
        [.int(2)], [.int(4)], [.int(4)], [.int(3)], [.int(3)],
    ]
    private static let singleIntLayout: [TestSource.Column] = [.int64]

    // MARK: - Helpers

    /// Splits `s` into lines (each ending in `\n`), sorts them, then joins
    /// them back. Tests that don't care about emission order assert against
    /// this.
    private static func sortOutput(_ s: String) -> String {
        let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        let lines = parts.map { String($0) }
        var withTrailing: [String] = []
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty { continue }
            withTrailing.append(line + "\n")
        }
        withTrailing.sort()
        return withTrailing.joined()
    }

    // MARK: - Register

    @Test func register() {
        let i1 = Register.from(int: 12345)
        let i2 = Register.from(int: 67890)
        let i3 = Register.from(int: 12345)
        let s1 = Register.from(string: "this is a string")
        let s2 = Register.from(string: "yet another stri")
        let s3 = Register.from(string: "this is a string")

        #expect(i1.kind == .int64)
        #expect(i2.kind == .int64)
        #expect(i3.kind == .int64)
        #expect(s1.kind == .char16)
        #expect(s2.kind == .char16)
        #expect(s3.kind == .char16)

        #expect(i1.asInt == 12345)
        #expect(i2.asInt == 67890)
        #expect(i3.asInt == 12345)
        #expect(s1.asString == "this is a string")
        #expect(s2.asString == "yet another stri")
        #expect(s3.asString == "this is a string")

        #expect(i1 != i2)
        #expect(i1 == i3)
        #expect(i1 != s1)
        #expect(s1 != s2)
        #expect(s1 == s3)
        #expect(s1 != i2)

        #expect(i1 < i2)
        #expect(i1 <= i2)
        #expect(i2 > i3)
        #expect(i2 >= i3)
        #expect(i1 >= i3)

        #expect(s1 < s2)
        #expect(s1 <= s2)
        #expect(s2 > s3)
        #expect(s2 >= s3)
        #expect(s1 >= s3)

        #expect(i1.hashValue == i3.hashValue)
        #expect(s1.hashValue == s3.hashValue)
    }

    @Test func registerDouble() {
        let d1 = Register.from(double: 3.14)
        let d2 = Register.from(double: 2.71)
        let d3 = Register.from(double: 3.14)
        #expect(d1.kind == .double)
        #expect(d1.asDouble == 3.14)
        #expect(d1 == d3)
        #expect(d1 != d2)
        #expect(d2 < d1)
        #expect(d1 > d2)
        #expect(d1.hashValue == d3.hashValue)
    }

    @Test func registerBool() {
        let t = Register.from(bool: true)
        let f = Register.from(bool: false)
        let t2 = Register.from(bool: true)
        #expect(t.kind == .bool)
        #expect(t.asBool == true)
        #expect(f.asBool == false)
        #expect(t == t2)
        #expect(t != f)
        #expect(f < t)
        #expect(t > f)
        #expect(t.hashValue == t2.hashValue)
    }

    @Test func registerCopyAssign() {
        let src = Register.from(double: 1.5)
        let dst = Register()
        dst.assign(from: src)
        #expect(dst.kind == .double)
        #expect(dst.asDouble == 1.5)

        let copy = src.copy()
        #expect(copy.kind == .double)
        #expect(copy.asDouble == 1.5)
    }

    // MARK: - CrossProduct

    @Test func crossProductBasic() {
        let left = TestSource(
            layout: [.int64],
            rows: [
                [.int(1)], [.int(2)],
            ])
        let right = TestSource(
            layout: [.int64],
            rows: [
                [.int(10)], [.int(20)], [.int(30)],
            ])
        let cp = CrossProduct(inputLeft: left, inputRight: right)
        cp.open()
        var pairs: [(Int64, Int64)] = []
        while cp.next() {
            let row = cp.getOutput()
            pairs.append((row[0].asInt, row[1].asInt))
        }
        cp.close()
        // 2 * 3 = 6 pairs, every (l, r) combination.
        #expect(pairs.count == 6)
        let set = Set(pairs.map { "\($0.0),\($0.1)" })
        #expect(set == Set(["1,10", "1,20", "1,30", "2,10", "2,20", "2,30"]))
    }

    @Test func crossProductEmptyLeft() {
        let left = TestSource(layout: [.int64], rows: [])
        let right = TestSource(layout: [.int64], rows: [[.int(1)]])
        let cp = CrossProduct(inputLeft: left, inputRight: right)
        cp.open()
        #expect(!cp.next())
        cp.close()
    }

    @Test func crossProductEmptyRight() {
        let left = TestSource(layout: [.int64], rows: [[.int(1)]])
        let right = TestSource(layout: [.int64], rows: [])
        let cp = CrossProduct(inputLeft: left, inputRight: right)
        cp.open()
        #expect(!cp.next())
        cp.close()
    }

    // MARK: - Print / Projection / Select

    @Test func printAll() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let output = TextOutput()
        let print = Print(input: source, stream: output)
        print.open()
        #expect(source.opened)
        #expect(!source.closed)
        while print.next() {}
        print.close()
        #expect(source.closed)
        let expected = ("24002,Xenokrates      \n" + "26120,Fichte          \n" + "29555,Feuerbach       \n")
        #expect(output.contents == expected)
    }

    @Test func projection() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let proj = Projection(input: source, attrIndexes: [0])
        let output = TextOutput()
        let print = Print(input: proj, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("24002\n" + "26120\n" + "29555\n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    @Test func selectIntEq() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let select = Select(
            input: source,
            predicate: Select.PredicateAttributeInt64(attrIndex: 0, constant: 26120, predicateType: .eq)
        )
        let output = TextOutput()
        let print = Print(input: select, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "26120,Fichte          \n")
    }

    @Test func selectStringEq() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let select = Select(
            input: source,
            predicate: Select.PredicateAttributeChar16(
                attrIndex: 1, constant: "Feuerbach       ", predicateType: .eq)
        )
        let output = TextOutput()
        let print = Print(input: select, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "29555,Feuerbach       \n")
    }

    @Test func selectIntNe() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let select = Select(
            input: source,
            predicate: Select.PredicateAttributeInt64(attrIndex: 0, constant: 26120, predicateType: .ne)
        )
        let output = TextOutput()
        let print = Print(input: select, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("24002,Xenokrates      \n" + "29555,Feuerbach       \n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    @Test func selectIntLower() {
        for ptype in [Select.PredicateType.lt, .le] {
            let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
            let select = Select(
                input: source,
                predicate: Select.PredicateAttributeInt64(attrIndex: 0, constant: 25000, predicateType: ptype)
            )
            let output = TextOutput()
            let print = Print(input: select, stream: output)
            print.open()
            while print.next() {}
            print.close()
            #expect(Self.sortOutput(output.contents) == "24002,Xenokrates      \n")
        }
    }

    @Test func selectIntGreater() {
        for ptype in [Select.PredicateType.gt, .ge] {
            let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
            let select = Select(
                input: source,
                predicate: Select.PredicateAttributeInt64(attrIndex: 0, constant: 25000, predicateType: ptype)
            )
            let output = TextOutput()
            let print = Print(input: select, stream: output)
            print.open()
            while print.next() {}
            print.close()
            let expected = ("26120,Fichte          \n" + "29555,Feuerbach       \n")
            #expect(Self.sortOutput(output.contents) == expected)
        }
    }

    @Test func selectAttrAttr() {
        let numbers: [[TestSource.ColumnValue]] = [
            [.int(1), .int(1)], [.int(1), .int(2)], [.int(1), .int(3)], [.int(1), .int(4)],
            [.int(2), .int(1)], [.int(2), .int(3)], [.int(3), .int(2)],
        ]
        let source = TestSource(layout: [.int64, .int64], rows: numbers)
        let select = Select(
            input: source,
            predicate: Select.PredicateAttributeAttribute(attrLeftIndex: 0, attrRightIndex: 1, predicateType: .ge)
        )
        let output = TextOutput()
        let print = Print(input: select, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("1,1\n" + "2,1\n" + "3,2\n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    // MARK: - Sort

    @Test func sort() {
        let source = TestSource(layout: Self.gradesLayout, rows: Self.relationGrades)
        let sort = Sort(
            input: source,
            criteria: [
                Sort.Criterion(attrIndex: 0, descending: true),
                Sort.Criterion(attrIndex: 2, descending: false),
            ])
        let output = TextOutput()
        let print = Print(input: sort, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("29555,4630,2\n" + "24002,5001,1\n" + "24002,5041,2\n")
        #expect(output.contents == expected)
    }

    // MARK: - HashJoin

    @Test func hashJoin() {
        let students = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let grades = TestSource(layout: Self.gradesLayout, rows: Self.relationGrades)
        let join = HashJoin(inputLeft: students, inputRight: grades, attrIndexLeft: 0, attrIndexRight: 0)
        let output = TextOutput()
        let print = Print(input: join, stream: output)
        print.open()
        #expect(students.opened)
        #expect(grades.opened)
        while print.next() {}
        print.close()
        #expect(students.closed)
        #expect(grades.closed)
        let expected =
            ("24002,Xenokrates      ,24002,5001,1\n" + "24002,Xenokrates      ,24002,5041,2\n"
                + "29555,Feuerbach       ,29555,4630,2\n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    // MARK: - HashAggregation

    @Test func hashAggregationMinMax() {
        let source = TestSource(layout: Self.studentsLayout, rows: Self.relationStudents)
        let agg = HashAggregation(
            input: source,
            groupByAttrs: [],
            aggrFuncs: [
                HashAggregation.AggrFunc(function: .min, attrIndex: 1),
                HashAggregation.AggrFunc(function: .max, attrIndex: 1),
            ]
        )
        let output = TextOutput()
        let print = Print(input: agg, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "Feuerbach       ,Xenokrates      \n")
    }

    @Test func hashAggregationSumCount() {
        let source = TestSource(layout: Self.gradesLayout, rows: Self.relationGrades)
        let agg = HashAggregation(
            input: source,
            groupByAttrs: [0],
            aggrFuncs: [
                HashAggregation.AggrFunc(function: .sum, attrIndex: 2),
                HashAggregation.AggrFunc(function: .count, attrIndex: 0),
            ]
        )
        let output = TextOutput()
        let print = Print(input: agg, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("24002,3,2\n" + "29555,2,1\n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    // MARK: - Set ops

    @Test func union() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let union = Union(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: union, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "1\n2\n3\n4\n")
    }

    @Test func unionAll() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let union = UnionAll(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: union, stream: output)
        print.open()
        while print.next() {}
        print.close()
        let expected = ("1\n1\n2\n2\n3\n3\n3\n3\n3\n4\n4\n")
        #expect(Self.sortOutput(output.contents) == expected)
    }

    @Test func intersect() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let intersect = Intersect(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: intersect, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "2\n3\n")
    }

    @Test func intersectAll() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let intersect = IntersectAll(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: intersect, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "2\n3\n3\n")
    }

    @Test func except() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let except = Except(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: except, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "1\n")
    }

    @Test func exceptAll() {
        let left = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetA)
        let right = TestSource(layout: Self.singleIntLayout, rows: Self.relationSetB)
        let except = ExceptAll(inputLeft: left, inputRight: right)
        let output = TextOutput()
        let print = Print(input: except, stream: output)
        print.open()
        while print.next() {}
        print.close()
        #expect(Self.sortOutput(output.contents) == "1\n1\n3\n")
    }
}
