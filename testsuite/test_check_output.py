import numpy as np
import os
import pytest

def read_conquest_out(path=".", filename="Conquest_out"):
    '''
    Reads a predefined set of values from a Conquest output file (typically
    named Conquest_out) by matching a string on the line. Currently we read
    Harris-Foulkes energy, Maximum force, Force Residual and Total stress.
    Returns a dictionary with float values.
    '''
    path_to_file = os.path.join(path,filename)
    assert os.path.exists(path_to_file)
    file = open(path_to_file, 'r')
    Results = dict()
    for line in file.readlines():
        if line.find("Harris-Foulkes energy") >= 0:
            Results['Harris-Foulkes energy'] = float(line.split("=")[1].split()[0])
        if line.find("Maximum force") >= 0:
            Results['Max force'] = float(line.split(":")[2].split("(")[0])
        if line.find("Force Residual") >= 0:
            Results['Force residual'] = float(line.split(":")[2].split()[0])
        if line.find("Total stress") >= 0:
            Results['Total stress'] = np.array(line.split(":")[2].split()[:-1], dtype=float)
        if line.find("Total polarisation") >= 0:
            Results['Total polarisation'] = float(line.split(":")[1].split()[0])

    return Results

def results(path, key):
    '''
    Reads a result and its reference, selects one value with key and returns it.
    '''
    ref_result = read_conquest_out(path, "Conquest_out.ref")
    test_result = read_conquest_out(path, "Conquest_out")

    return (ref_result[key], test_result[key])

@pytest.fixture
def precision():
    '''
    Return the relative tolerance used by tests
    '''

    return 1e-4

@pytest.mark.parametrize("key",['Harris-Foulkes energy',
                                'Max force',
                                'Force residual',
                                'Total stress'])
def test_001(key, precision):

    res = results("test_001_bulk_Si_1proc_Diag", key)
    np.testing.assert_allclose(res[0], res[1], rtol = precision, verbose = True)

@pytest.mark.parametrize("key", ['Harris-Foulkes energy',
                                 'Max force',
                                 'Force residual',
                                 'Total stress'])
def test_002(key, precision):

    res = results("test_002_bulk_Si_1proc_OrderN", key)
    np.testing.assert_allclose(res[0], res[1], rtol = precision, verbose = True)

@pytest.mark.parametrize("key", ['Harris-Foulkes energy',
                                 'Max force',
                                 'Force residual',
                                 'Total polarisation'])
def test_003(key, precision):

    res = results("test_003_bulk_BTO_polarisation", key)
    np.testing.assert_allclose(res[0], res[1], rtol = precision, verbose = True)
