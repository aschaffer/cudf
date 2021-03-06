# Copyright (c) 2020, NVIDIA CORPORATION.

import pandas as pd

from libcpp cimport bool
from libcpp.memory cimport make_unique, unique_ptr
from libcpp.vector cimport vector
from libc.stdint cimport int32_t

from cudf._libxx.column cimport Column
from cudf._libxx.scalar cimport Scalar
from cudf._libxx.table cimport Table
from cudf._libxx.move cimport move
from cudf._libxx.scalar cimport Scalar
from cudf._libxx.table cimport Table

from cudf._libxx.cpp.column.column cimport column
from cudf._libxx.cpp.column.column_view cimport (
    column_view,
    mutable_column_view
)
from cudf._libxx.cpp.libcpp.functional cimport reference_wrapper
from cudf._libxx.cpp.scalar.scalar cimport scalar
from cudf._libxx.cpp.table.table cimport table
from cudf._libxx.cpp.table.table_view cimport table_view
from cudf._libxx.cpp.types cimport size_type
cimport cudf._libxx.cpp.copying as cpp_copying


def copy_column(Column input_column):
    """
    Deep copies a column

    Parameters
    ----------
    input_columns : column to be copied

    Returns
    -------
    Deep copied column
    """

    cdef column_view input_column_view = input_column.view()
    cdef unique_ptr[column] c_result
    with nogil:
        c_result = move(make_unique[column](input_column_view))

    return Column.from_unique_ptr(move(c_result))


def _copy_range_in_place(Column input_column,
                         Column target_column,
                         size_type input_begin,
                         size_type input_end,
                         size_type target_begin):

    cdef column_view input_column_view = input_column.view()
    cdef mutable_column_view target_column_view = target_column.mutable_view()
    cdef size_type c_input_begin = input_begin
    cdef size_type c_input_end = input_end
    cdef size_type c_target_begin = target_begin

    with nogil:
        cpp_copying.copy_range_in_place(
            input_column_view,
            target_column_view,
            c_input_begin,
            c_input_end,
            c_target_begin)


def _copy_range(Column input_column,
                Column target_column,
                size_type input_begin,
                size_type input_end,
                size_type target_begin):

    cdef column_view input_column_view = input_column.view()
    cdef column_view target_column_view = target_column.view()
    cdef size_type c_input_begin = input_begin
    cdef size_type c_input_end = input_end
    cdef size_type c_target_begin = target_begin

    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(cpp_copying.copy_range(
            input_column_view,
            target_column_view,
            c_input_begin,
            c_input_end,
            c_target_begin)
        )

    return Column.from_unique_ptr(move(c_result))


def copy_range(Column input_column,
               Column target_column,
               size_type input_begin,
               size_type input_end,
               size_type target_begin,
               size_type target_end,
               bool inplace):
    """
    Copy input_column from input_begin to input_end to
    target_column from target_begin to target_end
    """

    if abs(target_end - target_begin) <= 1:
        return target_column

    if target_begin < 0:
        target_begin = target_begin + target_column.size

    if target_end < 0:
        target_end = target_end + target_column.size

    if target_begin > target_end:
        return target_column

    if inplace is True:
        _copy_range_in_place(input_column, target_column,
                             input_begin, input_end, target_begin)
    else:
        return _copy_range(input_column, target_column,
                           input_begin, input_end, target_begin)


def gather(Table source_table, Column gather_map):
    assert pd.api.types.is_integer_dtype(gather_map.dtype)

    cdef unique_ptr[table] c_result
    cdef table_view source_table_view = source_table.view()
    cdef column_view gather_map_view = gather_map.view()

    with nogil:
        c_result = move(
            cpp_copying.gather(
                source_table_view,
                gather_map_view
            )
        )

    return Table.from_unique_ptr(
        move(c_result),
        column_names=source_table._column_names,
        index_names=(
            None if (
                source_table._index is None) else source_table._index_names
        )
    )


def _scatter_table(Table source_table, Column scatter_map,
                   Table target_table, bool bounds_check=True):

    cdef table_view source_table_view = source_table.data_view()
    cdef column_view scatter_map_view = scatter_map.view()
    cdef table_view target_table_view = target_table.data_view()
    cdef bool c_bounds_check = bounds_check

    cdef unique_ptr[table] c_result

    with nogil:
        c_result = move(
            cpp_copying.scatter(
                source_table_view,
                scatter_map_view,
                target_table_view,
                c_bounds_check
            )
        )

    out_table = Table.from_unique_ptr(
        move(c_result),
        column_names=target_table._column_names,
        index_names=None
    )

    out_table._index = (
        None if target_table._index is None else target_table._index.copy(
            deep=False)
    )

    return out_table


def _scatter_scalar(scalars, Column scatter_map,
                    Table target_table, bool bounds_check=True):

    cdef vector[unique_ptr[scalar]] source_scalars
    source_scalars.reserve(len(scalars))
    cdef bool c_bounds_check = bounds_check
    cdef Scalar slr
    for val, col in zip(scalars, target_table._columns):
        slr = Scalar(val, col.dtype)
        source_scalars.push_back(move(slr.c_value))
    cdef column_view scatter_map_view = scatter_map.view()
    cdef table_view target_table_view = target_table.data_view()

    cdef unique_ptr[table] c_result

    with nogil:
        c_result = move(
            cpp_copying.scatter(
                source_scalars,
                scatter_map_view,
                target_table_view,
                c_bounds_check
            )
        )

    out_table = Table.from_unique_ptr(
        move(c_result),
        column_names=target_table._column_names,
        index_names=None
    )

    out_table._index = (
        None if target_table._index is None else target_table._index.copy(
            deep=False)
    )

    return out_table


def scatter(object input, object scatter_map, Table target,
            bool bounds_check=True):
    """
    Scattering input into taregt as per the scatter map,
    input can be a list of scalars or can be a table
    """

    from cudf.core.column.column import as_column

    if not isinstance(scatter_map, Column):
        scatter_map = as_column(scatter_map)

    if isinstance(input, Table):
        return _scatter_table(input, scatter_map, target, bounds_check)
    else:
        return _scatter_scalar(input, scatter_map, target, bounds_check)


def scatter_to_tables(Table source_table, Column partition_map):
    """
    Scatter the source_table to a set of tables as per the partition_map
    """

    cdef table_view source_table_view = source_table.view()
    cdef column_view partition_map_view = partition_map.view()

    cdef vector[unique_ptr[table]] c_result

    with nogil:
        c_result = move(cpp_copying.scatter_to_tables(
            source_table_view,
            partition_map_view
        ))

    result = [
        Table.from_unique_ptr(
            move(c_result[i]),
            column_names=source_table._column_names,
            index_names=source_table._index._column_names
        ) for i in range(c_result.size())]

    return result


def column_empty_like(Column input_column):

    cdef column_view input_column_view = input_column.view()
    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(cpp_copying.empty_like(input_column_view))

    return Column.from_unique_ptr(move(c_result))


def column_allocate_like(Column input_column, size=None):

    cdef size_type c_size = 0
    cdef column_view input_column_view = input_column.view()
    cdef unique_ptr[column] c_result

    if size is None:
        with nogil:
            c_result = move(cpp_copying.allocate_like(
                input_column_view,
                cpp_copying.mask_allocation_policy.RETAIN)
            )
    else:
        c_size = size
        with nogil:
            c_result = move(cpp_copying.allocate_like(
                input_column_view,
                c_size,
                cpp_copying.mask_allocation_policy.RETAIN)
            )

    return Column.from_unique_ptr(move(c_result))


def table_empty_like(Table input_table):

    cdef table_view input_table_view = input_table.view()
    cdef unique_ptr[table] c_result

    with nogil:
        c_result = move(cpp_copying.empty_like(input_table_view))

    return Table.from_unique_ptr(
        move(c_result),
        column_names=input_table._column_names,
        index_names=input_table._index._column_names
    )


def column_slice(Column input_column, object indices):

    cdef column_view input_column_view = input_column.view()
    cdef vector[size_type] c_indices
    c_indices.reserve(len(indices))

    cdef vector[column_view] c_result

    cdef int index

    for index in indices:
        c_indices.push_back(index)

    with nogil:
        c_result = move(
            cpp_copying.slice(
                input_column_view,
                c_indices)
        )

    num_of_result_cols = c_result.size()
    result = [
        Column.from_column_view(
            c_result[i],
            input_column) for i in range(num_of_result_cols)]

    return result


def table_slice(Table input_table, object indices):

    cdef table_view input_table_view = input_table.view()
    cdef vector[size_type] c_indices
    c_indices.reserve(len(indices))

    cdef vector[table_view] c_result

    cdef int index
    for index in indices:
        c_indices.push_back(index)

    with nogil:
        c_result = move(
            cpp_copying.slice(
                input_table_view,
                c_indices)
        )

    num_of_result_cols = c_result.size()
    result =[
        Table.from_table_view(
            c_result[i],
            input_table,
            column_names=input_table._column_names,
            index_names=input_table._index._column_names
        ) for i in range(num_of_result_cols)]

    return result


def column_split(Column input_column, object splits):

    cdef column_view input_column_view = input_column.view()
    cdef vector[size_type] c_splits
    c_splits.reserve(len(splits))

    cdef vector[column_view] c_result

    cdef int split

    for split in splits:
        c_splits.push_back(split)

    with nogil:
        c_result = move(
            cpp_copying.split(
                input_column_view,
                c_splits)
        )

    num_of_result_cols = c_result.size()
    result = [
        Column.from_column_view(
            c_result[i],
            input_column
        ) for i in range(num_of_result_cols)
    ]

    return result


def table_split(Table input_table, object splits):

    cdef table_view input_table_view = input_table.view()
    cdef vector[size_type] c_splits
    c_splits.reserve(len(splits))

    cdef vector[table_view] c_result

    cdef int split
    for split in splits:
        c_splits.push_back(split)

    with nogil:
        c_result = move(
            cpp_copying.split(
                input_table_view,
                c_splits)
        )

    num_of_result_cols = c_result.size()
    result = [
        Table.from_table_view(
            c_result[i],
            input_table,
            column_names=input_table._column_names,
            index_names=input_table._index._column_names
        ) for i in range(num_of_result_cols)]

    return result


def _copy_if_else_column_column(Column lhs, Column rhs, Column boolean_mask):

    cdef column_view lhs_view = lhs.view()
    cdef column_view rhs_view = rhs.view()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(
            cpp_copying.copy_if_else(
                lhs_view,
                rhs_view,
                boolean_mask_view
            )
        )

    return Column.from_unique_ptr(move(c_result))


def _copy_if_else_scalar_column(Scalar lhs, Column rhs, Column boolean_mask):

    cdef scalar* lhs_scalar = lhs.c_value.get()
    cdef column_view rhs_view = rhs.view()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(
            cpp_copying.copy_if_else(
                lhs_scalar[0],
                rhs_view,
                boolean_mask_view
            )
        )

    return Column.from_unique_ptr(move(c_result))


def _copy_if_else_column_scalar(Column lhs, Scalar rhs, Column boolean_mask):

    cdef column_view lhs_view = lhs.view()
    cdef scalar* rhs_scalar = rhs.c_value.get()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(
            cpp_copying.copy_if_else(
                lhs_view,
                rhs_scalar[0],
                boolean_mask_view
            )
        )

    return Column.from_unique_ptr(move(c_result))


def _copy_if_else_scalar_scalar(Scalar lhs, Scalar rhs, Column boolean_mask):

    cdef scalar* lhs_scalar = lhs.c_value.get()
    cdef scalar* rhs_scalar = rhs.c_value.get()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[column] c_result

    with nogil:
        c_result = move(
            cpp_copying.copy_if_else(
                lhs_scalar[0],
                rhs_scalar[0],
                boolean_mask_view
            )
        )

    return Column.from_unique_ptr(move(c_result))


def copy_if_else(object lhs, object rhs, Column boolean_mask):

    if isinstance(lhs, Column):
        if isinstance(rhs, Column):
            return _copy_if_else_column_column(lhs, rhs, boolean_mask)
        else:
            return _copy_if_else_column_scalar(
                lhs, Scalar(rhs, lhs.dtype), boolean_mask)
    else:
        if isinstance(rhs, Column):
            return _copy_if_else_scalar_column(
                Scalar(lhs, rhs.dtype), rhs, boolean_mask)
        else:
            if lhs is None and rhs is None:
                return lhs

            return _copy_if_else_scalar_scalar(
                Scalar(lhs), Scalar(rhs), boolean_mask)


def _boolean_mask_scatter_table(Table input_table, Table target_table,
                                Column boolean_mask):

    cdef table_view input_table_view = input_table.view()
    cdef table_view target_table_view = target_table.view()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[table] c_result

    with nogil:
        c_result = move(
            cpp_copying.boolean_mask_scatter(
                input_table_view,
                target_table_view,
                boolean_mask_view
            )
        )

    return Table.from_unique_ptr(
        move(c_result),
        column_names=target_table._column_names,
        index_names=target_table._index._column_names
    )


def _boolean_mask_scatter_scalar(list input_scalars, Table target_table,
                                 Column boolean_mask):

    cdef vector[reference_wrapper[scalar]] input_scalar_vector
    input_scalar_vector.reserve(len(input_scalars))
    cdef Scalar scl
    for scl in input_scalars:
        input_scalar_vector.push_back(reference_wrapper[scalar](
            scl.c_value.get()[0]))
    cdef table_view target_table_view = target_table.view()
    cdef column_view boolean_mask_view = boolean_mask.view()

    cdef unique_ptr[table] c_result

    with nogil:
        c_result = move(
            cpp_copying.boolean_mask_scatter(
                input_scalar_vector,
                target_table_view,
                boolean_mask_view
            )
        )

    return Table.from_unique_ptr(
        move(c_result),
        column_names=target_table._column_names,
        index_names=target_table._index._column_names
    )


def boolean_mask_scatter(object input, Table target_table,
                         Column boolean_mask):

    if isinstance(input, Table):
        _boolean_mask_scatter_table(input, target_table, boolean_mask)
    else:
        scalar_list = [Scalar(i) for i in input]
        _boolean_mask_scatter_scalar(scalar_list, target_table, boolean_mask)


def shift(Column input, int offset, object fill_value=None):

    cdef Scalar fill

    if isinstance(fill_value, Scalar):
        fill = fill_value
    else:
        fill = Scalar(fill_value, input.dtype)

    cdef column_view c_input = input.view()
    cdef int32_t c_offset = offset
    cdef scalar* c_fill_value = fill.c_value.get()
    cdef unique_ptr[column] c_output

    with nogil:
        c_output = move(
            cpp_copying.shift(
                c_input,
                c_offset,
                c_fill_value[0]
            )
        )

    return Column.from_unique_ptr(move(c_output))
